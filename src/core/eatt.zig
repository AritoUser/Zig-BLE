//! # BT 5.2 Enhanced Attribute Protocol (EATT) Multiplexer
//!
//! Strictly conforms to Bluetooth Core Specification v5.2 / v5.4 (Vol 3, Part A Section 10 & Part F/G).
//! Implements multi-channel ATT concurrency over L2CAP Enhanced Credit-Based Flow Control Mode
//! (CIDs `0x0040..0x007F`), including:
//! - **L2CAP Credit-Based Flow Control**: Tracks `local_credits` and `remote_credits` with credit
//!   exhaustion protection and credit overflow detection (Vol 3, Part A, 10.1).
//! - **K-Frame SDU Segmentation & Reassembly**: Splits ATT SDUs across `MPS`-sized L2CAP K-frames
//!   (with 2-byte LE SDU length header on the initial K-frame) and reassembles incoming K-frames.
//! - **Per-Bearer Error Isolation**: Protocol errors, timeouts, or credit violations on one EATT bearer
//!   isolate that bearer (`faulted = true`) without disrupting concurrent transactions on healthy bearers.
//! - **100% Zero-Allocation**: Backed by fixed-capacity compile-time arrays.

const std = @import("std");
const gatt = @import("gatt.zig");
const AttOpcode = gatt.AttOpcode;

pub const EattError = error{
    MaxBearersReached,
    BearerAlreadyExists,
    BearerNotFound,
    BearerFaulted,
    InsufficientCredits,
    CreditOverflow,
    SduExceedsMtu,
    KFrameExceedsMps,
    KFrameTooShort,
    SduLengthMismatch,
    BufferTooSmall,
};

/// State of an individual Enhanced ATT Bearer over L2CAP Credit-Based Flow Control.
pub const EattBearer = struct {
    /// L2CAP Channel Identifier (0x0040..0x007F)
    cid: u16,
    /// Negotiated SDU Maximum Transmission Unit (minimum 64 for EATT)
    mtu: u16,
    /// Maximum PDU Payload Size per L2CAP K-frame
    mps: u16,
    /// Credits available for local TX (granted by remote peer)
    remote_credits: u16 = 8,
    /// Credits available for remote TX (granted by local host)
    local_credits: u16 = 8,
    /// Indicates whether a Request-Response transaction is currently in-flight on this bearer
    in_flight: bool = false,
    /// Per-bearer fault isolation flag (set on timeout, credit violation, or SDU framing error)
    faulted: bool = false,
    /// Number of PDUs transmitted over this bearer
    tx_count: u32 = 0,

    // K-frame SDU reassembly state
    sdu_rx_buf: [517]u8 = @splat(0),
    sdu_rx_expected_len: u16 = 0,
    sdu_rx_written: u16 = 0,
    sdu_rx_in_progress: bool = false,

    /// Adds TX credits received via `LE Flow Control Credit` (`0x16`).
    /// Per Core Spec Vol 3, Part A, 10.1, exceeding 65535 credits faults the channel.
    pub fn addRemoteCredits(self: *EattBearer, credits: u16) EattError!void {
        if (self.faulted) return EattError.BearerFaulted;
        if (credits == 0) return;
        const res = @addWithOverflow(self.remote_credits, credits);
        if (res[1] != 0) {
            self.faulted = true;
            self.in_flight = false;
            return EattError.CreditOverflow;
        }
        self.remote_credits = res[0];
    }

    /// Replenishes RX credits granted to the peer and returns the new total `local_credits`.
    pub fn grantLocalCredits(self: *EattBearer, credits: u16) EattError!u16 {
        if (self.faulted) return EattError.BearerFaulted;
        const res = @addWithOverflow(self.local_credits, credits);
        if (res[1] != 0) return EattError.CreditOverflow;
        self.local_credits = res[0];
        return self.local_credits;
    }

    /// Computes how many L2CAP K-frames are required to transmit an SDU of `sdu_len` bytes.
    pub fn requiredKFrames(self: *const EattBearer, sdu_len: usize) EattError!usize {
        if (sdu_len > self.mtu) return EattError.SduExceedsMtu;
        if (self.mps < 3) return EattError.KFrameExceedsMps;
        const first_payload_cap = @as(usize, self.mps) - 2;
        if (sdu_len <= first_payload_cap) return 1;
        const rem = sdu_len - first_payload_cap;
        const extra = (rem + @as(usize, self.mps) - 1) / @as(usize, self.mps);
        return 1 + extra;
    }

    /// Segments an ATT SDU into MPS-sized L2CAP K-frames, consuming `remote_credits` atomically.
    /// First K-frame is prefixed with the 2-byte Little-Endian SDU length.
    /// Returns the number of K-frames written into `out_kframes` and their lengths in `out_lengths`.
    pub fn segmentSdu(
        self: *EattBearer,
        sdu: []const u8,
        out_kframes: []const []u8,
        out_lengths: []usize,
    ) EattError!usize {
        if (self.faulted) return EattError.BearerFaulted;
        if (sdu.len > self.mtu) return EattError.SduExceedsMtu;

        const needed = try self.requiredKFrames(sdu.len);
        if (self.remote_credits < needed) return EattError.InsufficientCredits;
        if (out_kframes.len < needed or out_lengths.len < needed) return EattError.BufferTooSmall;

        // First K-frame: [SDU_Length_LE (2B)] || [SDU_Data (up to MPS - 2)]
        const first_cap = @as(usize, self.mps) - 2;
        const first_data_len = @min(sdu.len, first_cap);
        if (out_kframes[0].len < 2 + first_data_len) return EattError.BufferTooSmall;
        std.mem.writeInt(u16, out_kframes[0][0..2], @intCast(sdu.len), .little);
        @memcpy(out_kframes[0][2 .. 2 + first_data_len], sdu[0..first_data_len]);
        out_lengths[0] = 2 + first_data_len;

        var offset: usize = first_data_len;
        var frame_idx: usize = 1;
        while (offset < sdu.len) : (frame_idx += 1) {
            const chunk = @min(sdu.len - offset, @as(usize, self.mps));
            if (out_kframes[frame_idx].len < chunk) return EattError.BufferTooSmall;
            @memcpy(out_kframes[frame_idx][0..chunk], sdu[offset .. offset + chunk]);
            out_lengths[frame_idx] = chunk;
            offset += chunk;
        }

        self.remote_credits -= @intCast(needed);
        return needed;
    }

    /// Feeds an incoming L2CAP K-frame into the bearer's reassembler, decrementing `local_credits`.
    /// Returns the reassembled SDU slice when complete, or `null` if more K-frames are awaited.
    pub fn feedKFrame(self: *EattBearer, kframe: []const u8) EattError!?[]const u8 {
        if (self.faulted) return EattError.BearerFaulted;
        if (self.local_credits == 0) {
            self.faulted = true;
            self.in_flight = false;
            return EattError.InsufficientCredits;
        }
        if (kframe.len > self.mps) {
            self.faulted = true;
            self.in_flight = false;
            return EattError.KFrameExceedsMps;
        }

        self.local_credits -= 1;

        if (!self.sdu_rx_in_progress) {
            if (kframe.len < 2) {
                self.faulted = true;
                return EattError.KFrameTooShort;
            }
            const total_sdu_len = std.mem.readInt(u16, kframe[0..2], .little);
            if (total_sdu_len > self.mtu or total_sdu_len > self.sdu_rx_buf.len) {
                self.faulted = true;
                return EattError.SduExceedsMtu;
            }
            const payload = kframe[2..];
            if (payload.len > total_sdu_len) {
                self.faulted = true;
                return EattError.SduLengthMismatch;
            }
            @memcpy(self.sdu_rx_buf[0..payload.len], payload);
            self.sdu_rx_expected_len = total_sdu_len;
            self.sdu_rx_written = @intCast(payload.len);

            if (self.sdu_rx_written == self.sdu_rx_expected_len) {
                self.sdu_rx_in_progress = false;
                return self.sdu_rx_buf[0..self.sdu_rx_expected_len];
            }
            self.sdu_rx_in_progress = true;
            return null;
        } else {
            if (@as(usize, self.sdu_rx_written) + kframe.len > self.sdu_rx_expected_len) {
                self.faulted = true;
                self.sdu_rx_in_progress = false;
                return EattError.SduLengthMismatch;
            }
            @memcpy(self.sdu_rx_buf[self.sdu_rx_written .. self.sdu_rx_written + kframe.len], kframe);
            self.sdu_rx_written += @intCast(kframe.len);

            if (self.sdu_rx_written == self.sdu_rx_expected_len) {
                self.sdu_rx_in_progress = false;
                return self.sdu_rx_buf[0..self.sdu_rx_expected_len];
            }
            return null;
        }
    }
};

/// High-performance, zero-allocation EATT channel multiplexer and load balancer.
pub fn EattMultiplexer(comptime max_bearers: usize) type {
    return struct {
        const Self = @This();

        bearers: [max_bearers]EattBearer = undefined,
        count: usize = 0,
        rr_index: usize = 0, // Round-robin cursor for notifications

        pub fn init() Self {
            return .{};
        }

        /// Registers a newly established L2CAP CoC channel as an active EATT bearer.
        pub fn addBearer(self: *Self, cid: u16, mtu: u16, mps: u16) EattError!void {
            return self.addBearerWithCredits(cid, mtu, mps, 8, 8);
        }

        /// Registers a newly established L2CAP CoC channel with explicit initial credits.
        pub fn addBearerWithCredits(
            self: *Self,
            cid: u16,
            mtu: u16,
            mps: u16,
            initial_remote_credits: u16,
            initial_local_credits: u16,
        ) EattError!void {
            if (self.count >= max_bearers) return EattError.MaxBearersReached;

            for (self.bearers[0..self.count]) |b| {
                if (b.cid == cid) return EattError.BearerAlreadyExists;
            }

            self.bearers[self.count] = EattBearer{
                .cid = cid,
                .mtu = mtu,
                .mps = mps,
                .remote_credits = initial_remote_credits,
                .local_credits = initial_local_credits,
                .in_flight = false,
                .faulted = false,
                .tx_count = 0,
            };
            self.count += 1;
        }

        /// Removes a disconnected bearer.
        pub fn removeBearer(self: *Self, cid: u16) bool {
            for (self.bearers[0..self.count], 0..) |b, i| {
                if (b.cid == cid) {
                    var j = i;
                    while (j + 1 < self.count) : (j += 1) {
                        self.bearers[j] = self.bearers[j + 1];
                    }
                    self.count -= 1;
                    if (self.rr_index >= self.count and self.count > 0) {
                        self.rr_index = 0;
                    }
                    return true;
                }
            }
            return false;
        }

        /// Isolates a faulted bearer (e.g., on ATT timeout or credit error) without affecting other bearers.
        pub fn isolateBearerFault(self: *Self, cid: u16) bool {
            if (self.getBearer(cid)) |b| {
                b.faulted = true;
                b.in_flight = false;
                b.sdu_rx_in_progress = false;
                return true;
            }
            return false;
        }

        /// Finds an idle, healthy bearer with available remote credits for a client request.
        /// Marks the bearer as `in_flight = true`. Returns `null` if all healthy bearers are busy or out of credits.
        pub fn acquireBearerForRequest(self: *Self) ?*EattBearer {
            for (self.bearers[0..self.count]) |*b| {
                if (!b.faulted and !b.in_flight and b.remote_credits > 0) {
                    b.in_flight = true;
                    b.tx_count += 1;
                    return b;
                }
            }
            return null;
        }

        /// Releases an in-flight bearer upon receiving the corresponding response.
        pub fn releaseBearer(self: *Self, cid: u16) bool {
            if (self.getBearer(cid)) |b| {
                if (b.faulted) return false;
                b.in_flight = false;
                return true;
            }
            return false;
        }

        /// Selects the optimal healthy bearer with available credits for unacknowledged notifications
        /// using round-robin load distribution across all active bearers.
        pub fn selectBearerForNotification(self: *Self) ?*EattBearer {
            if (self.count == 0) return null;

            var checked: usize = 0;
            while (checked < self.count) : (checked += 1) {
                const idx = self.rr_index % self.count;
                self.rr_index = (self.rr_index + 1) % self.count;
                const b = &self.bearers[idx];
                if (!b.faulted and b.remote_credits > 0) {
                    b.tx_count += 1;
                    return b;
                }
            }
            return null;
        }

        pub fn getBearer(self: *Self, cid: u16) ?*EattBearer {
            for (self.bearers[0..self.count]) |*b| {
                if (b.cid == cid) return b;
            }
            return null;
        }

        pub inline fn getActiveCount(self: *const Self) usize {
            return self.count;
        }

        pub fn getHealthyCount(self: *const Self) usize {
            var healthy: usize = 0;
            for (self.bearers[0..self.count]) |b| {
                if (!b.faulted) healthy += 1;
            }
            return healthy;
        }
    };
}

test "EattMultiplexer multi-bearer load balancing and HoL-prevention test" {
    var mux = EattMultiplexer(4).init();

    // Register 2 bearers (CIDs 0x0040 and 0x0041)
    try mux.addBearer(0x0040, 247, 247);
    try mux.addBearer(0x0041, 517, 251);
    try std.testing.expectEqual(@as(usize, 2), mux.getActiveCount());

    // 1. Acquire first bearer for a long read request
    const b1 = mux.acquireBearerForRequest().?;
    try std.testing.expectEqual(@as(u16, 0x0040), b1.cid);
    try std.testing.expect(b1.in_flight);

    // 2. Acquire second bearer concurrently for another write request (No Head-of-Line blocking!)
    const b2 = mux.acquireBearerForRequest().?;
    try std.testing.expectEqual(@as(u16, 0x0041), b2.cid);
    try std.testing.expect(b2.in_flight);

    // 3. Third request should fail because both are busy
    try std.testing.expect(mux.acquireBearerForRequest() == null);

    // 4. Release first bearer upon response
    try std.testing.expect(mux.releaseBearer(0x0040));
    try std.testing.expect(!b1.in_flight);

    // 5. Notifications round-robin across available bearers
    const notif1 = mux.selectBearerForNotification().?;
    const notif2 = mux.selectBearerForNotification().?;
    try std.testing.expect(notif1.cid != notif2.cid);

    // 6. Remove bearer
    try std.testing.expect(mux.removeBearer(0x0040));
    try std.testing.expectEqual(@as(usize, 1), mux.getActiveCount());
}

test "EattBearer: L2CAP K-Frame SDU Segmentation, Reassembly, Credit Exhaustion & Fault Isolation" {
    var mux = EattMultiplexer(4).init();
    // Register CID 0x0040 with MTU=64, MPS=23, 3 remote credits, 3 local credits
    try mux.addBearerWithCredits(0x0040, 64, 23, 3, 3);
    try mux.addBearerWithCredits(0x0041, 64, 23, 3, 3);

    const tx_bearer = mux.getBearer(0x0040).?;
    const rx_bearer = mux.getBearer(0x0041).?;

    // 50-byte ATT SDU requires 3 K-frames at MPS=23:
    // K-frame 0: 2B SDU len + 21B data (23B)
    // K-frame 1: 23B data
    // K-frame 2: 6B data
    const sdu_payload = "0123456789ABCDEFGHIJKLMNOPQRSTUVWXYZabcdefghijklmn";
    try std.testing.expectEqual(@as(usize, 50), sdu_payload.len);

    var kf0: [23]u8 = undefined;
    var kf1: [23]u8 = undefined;
    var kf2: [23]u8 = undefined;
    const kf_slices = [_][]u8{ &kf0, &kf1, &kf2 };
    var kf_lens: [3]usize = undefined;

    const kf_count = try tx_bearer.segmentSdu(sdu_payload, &kf_slices, &kf_lens);
    try std.testing.expectEqual(@as(usize, 3), kf_count);
    try std.testing.expectEqual(@as(u16, 0), tx_bearer.remote_credits);

    // Attempting to segment another SDU with 0 credits must return InsufficientCredits
    try std.testing.expectError(EattError.InsufficientCredits, tx_bearer.segmentSdu("abc", &kf_slices, &kf_lens));

    // Reassemble on rx_bearer
    try std.testing.expect((try rx_bearer.feedKFrame(kf0[0..kf_lens[0]])) == null);
    try std.testing.expect((try rx_bearer.feedKFrame(kf1[0..kf_lens[1]])) == null);
    const reassembled = (try rx_bearer.feedKFrame(kf2[0..kf_lens[2]])).?;
    try std.testing.expectEqualStrings(sdu_payload, reassembled);
    try std.testing.expectEqual(@as(u16, 0), rx_bearer.local_credits);

    // Feeding an extra K-frame when local_credits == 0 faults rx_bearer (0x0041) but keeps 0x0040 healthy!
    try std.testing.expectError(EattError.InsufficientCredits, rx_bearer.feedKFrame("x"));
    try std.testing.expect(rx_bearer.faulted);
    try std.testing.expect(!tx_bearer.faulted);
    try std.testing.expectEqual(@as(usize, 1), mux.getHealthyCount());
}
