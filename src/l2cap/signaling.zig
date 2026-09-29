//! # LE L2CAP Signaling Protocol Engine
//!
//! Compliant with Bluetooth Core Specification v5.4 / v6.0, Vol 3, Part A
//! (Logical Link Control and Adaptation Protocol), Section 4: Signaling Packet Formats.
//!
//! Designed specifically for LE-U logical links operating on fixed Channel ID (CID) 0x0005.
//!
//! Features:
//! - 100% Pure Zig, zero external dependencies, zero dynamic allocations (`no-alloc`).
//! - Complete zero-copy parsers and serializers for all standard LE Signaling PDUs.
//! - Enhanced Credit-Based Flow Control (Bluetooth 5.2+) support.
//! - Frame framing/deframing helper for standard 4-byte L2CAP Basic Information Frames (B-Frames).

const std = @import("std");

// -------------------------------------------------------------------------------------------------
// L2CAP Fixed Channel Identifiers (CIDs) - Core Spec Vol 3, Part A, Sec 2.1
// -------------------------------------------------------------------------------------------------

pub const CID_NULL: u16 = 0x0000;
pub const CID_SIGNALING_BREDR: u16 = 0x0001;
pub const CID_CONNECTIONLESS: u16 = 0x0002;
pub const CID_AMP_MANAGER: u16 = 0x0003;
pub const CID_ATT: u16 = 0x0004;
pub const CID_LE_SIGNALING: u16 = 0x0005;
pub const CID_SMP: u16 = 0x0006;
pub const CID_SMP_BREDR: u16 = 0x0007;

/// Dynamically allocated LE Connection-Oriented Channel (CoC) range (0x0040 - 0x007F)
pub const CID_LE_DYNAMIC_START: u16 = 0x0040;
pub const CID_LE_DYNAMIC_END: u16 = 0x007F;

// -------------------------------------------------------------------------------------------------
// L2CAP Signaling Error
// -------------------------------------------------------------------------------------------------

pub const L2capSignalingError = error{
    BufferTooShort,
    BufferTooSmall,
    InvalidOpcode,
    InvalidLength,
    InvalidParameter,
    InvalidCid,
    MtuExceeded,
};

// -------------------------------------------------------------------------------------------------
// L2CAP Basic Information Frame (B-frame) Header (Vol 3, Part A, Sec 3.1)
// -------------------------------------------------------------------------------------------------

/// Standard 4-byte L2CAP Frame Header
pub const L2capHeader = extern struct {
    length: u16,
    cid: u16,

    pub const HEADER_LEN: usize = 4;

    pub fn parse(raw: []const u8) L2capSignalingError!L2capHeader {
        if (raw.len < HEADER_LEN) return L2capSignalingError.BufferTooShort;
        return L2capHeader{
            .length = std.mem.readInt(u16, raw[0..2], .little),
            .cid = std.mem.readInt(u16, raw[2..4], .little),
        };
    }

    pub fn serialize(self: L2capHeader, dest: []u8) L2capSignalingError!usize {
        if (dest.len < HEADER_LEN) return L2capSignalingError.BufferTooSmall;
        std.mem.writeInt(u16, dest[0..2], self.length, .little);
        std.mem.writeInt(u16, dest[2..4], self.cid, .little);
        return HEADER_LEN;
    }
};

// -------------------------------------------------------------------------------------------------
// Signaling Command Header & Opcodes (Vol 3, Part A, Sec 4)
// -------------------------------------------------------------------------------------------------

pub const SignalingOpcode = enum(u8) {
    command_reject_rsp = 0x01,
    disconnection_req = 0x06,
    disconnection_rsp = 0x07,
    conn_param_update_req = 0x12,
    conn_param_update_rsp = 0x13,
    le_credit_based_conn_req = 0x14,
    le_credit_based_conn_rsp = 0x15,
    le_flow_control_credit = 0x16,
    credit_based_conn_req = 0x17, // Enhanced CoC (Bluetooth 5.2+)
    credit_based_conn_rsp = 0x18, // Enhanced CoC (Bluetooth 5.2+)
    credit_based_reconfigure_req = 0x19, // Enhanced CoC (Bluetooth 5.2+)
    credit_based_reconfigure_rsp = 0x1A, // Enhanced CoC (Bluetooth 5.2+)
    _,

    pub fn getName(self: SignalingOpcode) []const u8 {
        return switch (self) {
            .command_reject_rsp => "Command Reject Response",
            .disconnection_req => "Disconnection Request",
            .disconnection_rsp => "Disconnection Response",
            .conn_param_update_req => "Connection Parameter Update Request",
            .conn_param_update_rsp => "Connection Parameter Update Response",
            .le_credit_based_conn_req => "LE Credit Based Connection Request",
            .le_credit_based_conn_rsp => "LE Credit Based Connection Response",
            .le_flow_control_credit => "LE Flow Control Credit",
            .credit_based_conn_req => "Enhanced Credit Based Connection Request",
            .credit_based_conn_rsp => "Enhanced Credit Based Connection Response",
            .credit_based_reconfigure_req => "Credit Based Reconfigure Request",
            .credit_based_reconfigure_rsp => "Credit Based Reconfigure Response",
            _ => "Unknown Signaling Opcode",
        };
    }
};

/// 4-byte L2CAP Signaling Command Header
pub const SignalingHeader = extern struct {
    code: u8,
    identifier: u8,
    length: u16,

    pub const HEADER_LEN: usize = 4;

    pub fn parse(raw: []const u8) L2capSignalingError!SignalingHeader {
        if (raw.len < HEADER_LEN) return L2capSignalingError.BufferTooShort;
        return SignalingHeader{
            .code = raw[0],
            .identifier = raw[1],
            .length = std.mem.readInt(u16, raw[2..4], .little),
        };
    }

    pub fn serialize(self: SignalingHeader, dest: []u8) L2capSignalingError!usize {
        if (dest.len < HEADER_LEN) return L2capSignalingError.BufferTooSmall;
        dest[0] = self.code;
        dest[1] = self.identifier;
        std.mem.writeInt(u16, dest[2..4], self.length, .little);
        return HEADER_LEN;
    }
};

// -------------------------------------------------------------------------------------------------
// 1. Command Reject Response (Opcode 0x01)
// -------------------------------------------------------------------------------------------------

pub const CommandRejectReason = enum(u16) {
    not_understood = 0x0000,
    signaling_mtu_exceeded = 0x0001,
    invalid_cid = 0x0002,
    _,
};

pub const CommandRejectRsp = struct {
    identifier: u8,
    reason: CommandRejectReason,
    actual_mtu: ?u16 = null,
    source_cid: ?u16 = null,
    destination_cid: ?u16 = null,

    pub fn parse(raw: []const u8) L2capSignalingError!CommandRejectRsp {
        if (raw.len < 6) return L2capSignalingError.BufferTooShort;
        if (raw[0] != @intFromEnum(SignalingOpcode.command_reject_rsp)) return L2capSignalingError.InvalidOpcode;

        const id = raw[1];
        const payload_len = std.mem.readInt(u16, raw[2..4], .little);
        if (raw.len < 4 + payload_len or payload_len < 2) return L2capSignalingError.InvalidLength;

        const reason_raw = std.mem.readInt(u16, raw[4..6], .little);
        const reason: CommandRejectReason = @enumFromInt(reason_raw);

        var actual_mtu: ?u16 = null;
        var scid: ?u16 = null;
        var dcid: ?u16 = null;

        if (reason == .signaling_mtu_exceeded and payload_len >= 4) {
            actual_mtu = std.mem.readInt(u16, raw[6..8], .little);
        } else if (reason == .invalid_cid and payload_len >= 6) {
            scid = std.mem.readInt(u16, raw[6..8], .little);
            dcid = std.mem.readInt(u16, raw[8..10], .little);
        }

        return CommandRejectRsp{
            .identifier = id,
            .reason = reason,
            .actual_mtu = actual_mtu,
            .source_cid = scid,
            .destination_cid = dcid,
        };
    }

    pub fn serialize(self: CommandRejectRsp, dest: []u8) L2capSignalingError!usize {
        var payload_len: u16 = 2;
        if (self.reason == .signaling_mtu_exceeded) {
            payload_len = 4;
        } else if (self.reason == .invalid_cid) {
            payload_len = 6;
        }

        const total_len = 4 + payload_len;
        if (dest.len < total_len) return L2capSignalingError.BufferTooSmall;

        dest[0] = @intFromEnum(SignalingOpcode.command_reject_rsp);
        dest[1] = self.identifier;
        std.mem.writeInt(u16, dest[2..4], payload_len, .little);
        std.mem.writeInt(u16, dest[4..6], @intFromEnum(self.reason), .little);

        if (self.reason == .signaling_mtu_exceeded) {
            std.mem.writeInt(u16, dest[6..8], self.actual_mtu orelse 0, .little);
        } else if (self.reason == .invalid_cid) {
            std.mem.writeInt(u16, dest[6..8], self.source_cid orelse 0, .little);
            std.mem.writeInt(u16, dest[8..10], self.destination_cid orelse 0, .little);
        }

        return total_len;
    }
};

// -------------------------------------------------------------------------------------------------
// 2. Disconnection Request / Response (Opcodes 0x06, 0x07)
// -------------------------------------------------------------------------------------------------

pub const DisconnectionReq = struct {
    identifier: u8,
    destination_cid: u16,
    source_cid: u16,

    pub const PDU_LEN: usize = 8;

    pub fn parse(raw: []const u8) L2capSignalingError!DisconnectionReq {
        if (raw.len < PDU_LEN) return L2capSignalingError.BufferTooShort;
        if (raw[0] != @intFromEnum(SignalingOpcode.disconnection_req)) return L2capSignalingError.InvalidOpcode;
        const len = std.mem.readInt(u16, raw[2..4], .little);
        if (len != 4) return L2capSignalingError.InvalidLength;

        return DisconnectionReq{
            .identifier = raw[1],
            .destination_cid = std.mem.readInt(u16, raw[4..6], .little),
            .source_cid = std.mem.readInt(u16, raw[6..8], .little),
        };
    }

    pub fn serialize(self: DisconnectionReq, dest: []u8) L2capSignalingError!usize {
        if (dest.len < PDU_LEN) return L2capSignalingError.BufferTooSmall;
        dest[0] = @intFromEnum(SignalingOpcode.disconnection_req);
        dest[1] = self.identifier;
        std.mem.writeInt(u16, dest[2..4], 4, .little);
        std.mem.writeInt(u16, dest[4..6], self.destination_cid, .little);
        std.mem.writeInt(u16, dest[6..8], self.source_cid, .little);
        return PDU_LEN;
    }
};

pub const DisconnectionRsp = struct {
    identifier: u8,
    destination_cid: u16,
    source_cid: u16,

    pub const PDU_LEN: usize = 8;

    pub fn parse(raw: []const u8) L2capSignalingError!DisconnectionRsp {
        if (raw.len < PDU_LEN) return L2capSignalingError.BufferTooShort;
        if (raw[0] != @intFromEnum(SignalingOpcode.disconnection_rsp)) return L2capSignalingError.InvalidOpcode;
        const len = std.mem.readInt(u16, raw[2..4], .little);
        if (len != 4) return L2capSignalingError.InvalidLength;

        return DisconnectionRsp{
            .identifier = raw[1],
            .destination_cid = std.mem.readInt(u16, raw[4..6], .little),
            .source_cid = std.mem.readInt(u16, raw[6..8], .little),
        };
    }

    pub fn serialize(self: DisconnectionRsp, dest: []u8) L2capSignalingError!usize {
        if (dest.len < PDU_LEN) return L2capSignalingError.BufferTooSmall;
        dest[0] = @intFromEnum(SignalingOpcode.disconnection_rsp);
        dest[1] = self.identifier;
        std.mem.writeInt(u16, dest[2..4], 4, .little);
        std.mem.writeInt(u16, dest[4..6], self.destination_cid, .little);
        std.mem.writeInt(u16, dest[6..8], self.source_cid, .little);
        return PDU_LEN;
    }
};

// -------------------------------------------------------------------------------------------------
// 3. Connection Parameter Update Request / Response (Opcodes 0x12, 0x13)
// -------------------------------------------------------------------------------------------------

pub const ConnParamUpdateReq = struct {
    identifier: u8,
    /// Minimum connection interval in units of 1.25ms (range: 6 to 3200, 7.5ms to 4.0s)
    interval_min: u16,
    /// Maximum connection interval in units of 1.25ms (range: 6 to 3200, 7.5ms to 4.0s)
    interval_max: u16,
    /// Slave latency (range: 0 to 499)
    latency: u16,
    /// Supervision timeout multiplier in units of 10ms (range: 10 to 3200, 100ms to 32.0s)
    timeout: u16,

    pub const PDU_LEN: usize = 12;

    pub fn parse(raw: []const u8) L2capSignalingError!ConnParamUpdateReq {
        if (raw.len < PDU_LEN) return L2capSignalingError.BufferTooShort;
        if (raw[0] != @intFromEnum(SignalingOpcode.conn_param_update_req)) return L2capSignalingError.InvalidOpcode;
        const len = std.mem.readInt(u16, raw[2..4], .little);
        if (len != 8) return L2capSignalingError.InvalidLength;

        return ConnParamUpdateReq{
            .identifier = raw[1],
            .interval_min = std.mem.readInt(u16, raw[4..6], .little),
            .interval_max = std.mem.readInt(u16, raw[6..8], .little),
            .latency = std.mem.readInt(u16, raw[8..10], .little),
            .timeout = std.mem.readInt(u16, raw[10..12], .little),
        };
    }

    pub fn serialize(self: ConnParamUpdateReq, dest: []u8) L2capSignalingError!usize {
        if (dest.len < PDU_LEN) return L2capSignalingError.BufferTooSmall;
        dest[0] = @intFromEnum(SignalingOpcode.conn_param_update_req);
        dest[1] = self.identifier;
        std.mem.writeInt(u16, dest[2..4], 8, .little);
        std.mem.writeInt(u16, dest[4..6], self.interval_min, .little);
        std.mem.writeInt(u16, dest[6..8], self.interval_max, .little);
        std.mem.writeInt(u16, dest[8..10], self.latency, .little);
        std.mem.writeInt(u16, dest[10..12], self.timeout, .little);
        return PDU_LEN;
    }
};

pub const ConnParamUpdateResult = enum(u16) {
    accepted = 0x0000,
    rejected = 0x0001,
    _,
};

pub const ConnParamUpdateRsp = struct {
    identifier: u8,
    result: ConnParamUpdateResult,

    pub const PDU_LEN: usize = 6;

    pub fn parse(raw: []const u8) L2capSignalingError!ConnParamUpdateRsp {
        if (raw.len < PDU_LEN) return L2capSignalingError.BufferTooShort;
        if (raw[0] != @intFromEnum(SignalingOpcode.conn_param_update_rsp)) return L2capSignalingError.InvalidOpcode;
        const len = std.mem.readInt(u16, raw[2..4], .little);
        if (len != 2) return L2capSignalingError.InvalidLength;

        return ConnParamUpdateRsp{
            .identifier = raw[1],
            .result = @enumFromInt(std.mem.readInt(u16, raw[4..6], .little)),
        };
    }

    pub fn serialize(self: ConnParamUpdateRsp, dest: []u8) L2capSignalingError!usize {
        if (dest.len < PDU_LEN) return L2capSignalingError.BufferTooSmall;
        dest[0] = @intFromEnum(SignalingOpcode.conn_param_update_rsp);
        dest[1] = self.identifier;
        std.mem.writeInt(u16, dest[2..4], 2, .little);
        std.mem.writeInt(u16, dest[4..6], @intFromEnum(self.result), .little);
        return PDU_LEN;
    }
};

// -------------------------------------------------------------------------------------------------
// 4. LE Credit Based Connection Request / Response (Opcodes 0x14, 0x15)
// -------------------------------------------------------------------------------------------------

pub const LeCreditConnResult = enum(u16) {
    success = 0x0000,
    spsm_not_supported = 0x0002,
    no_resources = 0x0004,
    insufficient_authentication = 0x0005,
    insufficient_authorization = 0x0006,
    encryption_key_too_short = 0x0007,
    insufficient_encryption = 0x0008,
    invalid_source_cid = 0x0009,
    source_cid_already_allocated = 0x000A,
    unacceptable_parameters = 0x000B,
    _,

    pub fn getName(self: LeCreditConnResult) []const u8 {
        return switch (self) {
            .success => "Connection successful",
            .spsm_not_supported => "LE_PSM not supported",
            .no_resources => "No resources available",
            .insufficient_authentication => "Insufficient authentication",
            .insufficient_authorization => "Insufficient authorization",
            .encryption_key_too_short => "Encryption key size too short",
            .insufficient_encryption => "Insufficient encryption",
            .invalid_source_cid => "Invalid Source CID",
            .source_cid_already_allocated => "Source CID already allocated",
            .unacceptable_parameters => "Unacceptable parameters",
            _ => "Unknown Result",
        };
    }
};

pub const LeCreditBasedConnReq = struct {
    identifier: u8,
    spsm: u16,
    source_cid: u16,
    mtu: u16,
    mps: u16,
    initial_credits: u16,

    pub const PDU_LEN: usize = 14;

    pub fn parse(raw: []const u8) L2capSignalingError!LeCreditBasedConnReq {
        if (raw.len < PDU_LEN) return L2capSignalingError.BufferTooShort;
        if (raw[0] != @intFromEnum(SignalingOpcode.le_credit_based_conn_req)) return L2capSignalingError.InvalidOpcode;
        const len = std.mem.readInt(u16, raw[2..4], .little);
        if (len != 10) return L2capSignalingError.InvalidLength;

        return LeCreditBasedConnReq{
            .identifier = raw[1],
            .spsm = std.mem.readInt(u16, raw[4..6], .little),
            .source_cid = std.mem.readInt(u16, raw[6..8], .little),
            .mtu = std.mem.readInt(u16, raw[8..10], .little),
            .mps = std.mem.readInt(u16, raw[10..12], .little),
            .initial_credits = std.mem.readInt(u16, raw[12..14], .little),
        };
    }

    pub fn serialize(self: LeCreditBasedConnReq, dest: []u8) L2capSignalingError!usize {
        if (dest.len < PDU_LEN) return L2capSignalingError.BufferTooSmall;
        dest[0] = @intFromEnum(SignalingOpcode.le_credit_based_conn_req);
        dest[1] = self.identifier;
        std.mem.writeInt(u16, dest[2..4], 10, .little);
        std.mem.writeInt(u16, dest[4..6], self.spsm, .little);
        std.mem.writeInt(u16, dest[6..8], self.source_cid, .little);
        std.mem.writeInt(u16, dest[8..10], self.mtu, .little);
        std.mem.writeInt(u16, dest[10..12], self.mps, .little);
        std.mem.writeInt(u16, dest[12..14], self.initial_credits, .little);
        return PDU_LEN;
    }
};

pub const LeCreditBasedConnRsp = struct {
    identifier: u8,
    destination_cid: u16,
    mtu: u16,
    mps: u16,
    initial_credits: u16,
    result: LeCreditConnResult,

    pub const PDU_LEN: usize = 14;

    pub fn parse(raw: []const u8) L2capSignalingError!LeCreditBasedConnRsp {
        if (raw.len < PDU_LEN) return L2capSignalingError.BufferTooShort;
        if (raw[0] != @intFromEnum(SignalingOpcode.le_credit_based_conn_rsp)) return L2capSignalingError.InvalidOpcode;
        const len = std.mem.readInt(u16, raw[2..4], .little);
        if (len != 10) return L2capSignalingError.InvalidLength;

        return LeCreditBasedConnRsp{
            .identifier = raw[1],
            .destination_cid = std.mem.readInt(u16, raw[4..6], .little),
            .mtu = std.mem.readInt(u16, raw[6..8], .little),
            .mps = std.mem.readInt(u16, raw[8..10], .little),
            .initial_credits = std.mem.readInt(u16, raw[10..12], .little),
            .result = @enumFromInt(std.mem.readInt(u16, raw[12..14], .little)),
        };
    }

    pub fn serialize(self: LeCreditBasedConnRsp, dest: []u8) L2capSignalingError!usize {
        if (dest.len < PDU_LEN) return L2capSignalingError.BufferTooSmall;
        dest[0] = @intFromEnum(SignalingOpcode.le_credit_based_conn_rsp);
        dest[1] = self.identifier;
        std.mem.writeInt(u16, dest[2..4], 10, .little);
        std.mem.writeInt(u16, dest[4..6], self.destination_cid, .little);
        std.mem.writeInt(u16, dest[6..8], self.mtu, .little);
        std.mem.writeInt(u16, dest[8..10], self.mps, .little);
        std.mem.writeInt(u16, dest[10..12], self.initial_credits, .little);
        std.mem.writeInt(u16, dest[12..14], @intFromEnum(self.result), .little);
        return PDU_LEN;
    }
};

// -------------------------------------------------------------------------------------------------
// 5. LE Flow Control Credit (Opcode 0x16)
// -------------------------------------------------------------------------------------------------

pub const LeFlowControlCredit = struct {
    identifier: u8,
    cid: u16,
    credits: u16,

    pub const PDU_LEN: usize = 8;

    pub fn parse(raw: []const u8) L2capSignalingError!LeFlowControlCredit {
        if (raw.len < PDU_LEN) return L2capSignalingError.BufferTooShort;
        if (raw[0] != @intFromEnum(SignalingOpcode.le_flow_control_credit)) return L2capSignalingError.InvalidOpcode;
        const len = std.mem.readInt(u16, raw[2..4], .little);
        if (len != 4) return L2capSignalingError.InvalidLength;

        return LeFlowControlCredit{
            .identifier = raw[1],
            .cid = std.mem.readInt(u16, raw[4..6], .little),
            .credits = std.mem.readInt(u16, raw[6..8], .little),
        };
    }

    pub fn serialize(self: LeFlowControlCredit, dest: []u8) L2capSignalingError!usize {
        if (dest.len < PDU_LEN) return L2capSignalingError.BufferTooSmall;
        dest[0] = @intFromEnum(SignalingOpcode.le_flow_control_credit);
        dest[1] = self.identifier;
        std.mem.writeInt(u16, dest[2..4], 4, .little);
        std.mem.writeInt(u16, dest[4..6], self.cid, .little);
        std.mem.writeInt(u16, dest[6..8], self.credits, .little);
        return PDU_LEN;
    }
};

// -------------------------------------------------------------------------------------------------
// 6. Enhanced Credit Based Connection Request / Response (Opcodes 0x17, 0x18 - BT 5.2+)
// -------------------------------------------------------------------------------------------------

pub const EnhancedCreditConnResult = enum(u16) {
    all_success = 0x0000,
    spsm_not_supported = 0x0002,
    no_resources = 0x0004,
    insufficient_authentication = 0x0005,
    insufficient_authorization = 0x0006,
    encryption_key_too_short = 0x0007,
    insufficient_encryption = 0x0008,
    some_cids_refused = 0x0009,
    invalid_parameters = 0x000A,
    _,
};

pub const CreditBasedConnReq = struct {
    identifier: u8,
    spsm: u16,
    mtu: u16,
    mps: u16,
    initial_credits: u16,
    source_cids: [5]u16 = [_]u16{0} ** 5,
    source_cid_count: u8 = 0,

    pub fn parse(raw: []const u8) L2capSignalingError!CreditBasedConnReq {
        if (raw.len < 14) return L2capSignalingError.BufferTooShort;
        if (raw[0] != @intFromEnum(SignalingOpcode.credit_based_conn_req)) return L2capSignalingError.InvalidOpcode;
        const len = std.mem.readInt(u16, raw[2..4], .little);
        if (len < 10 or (len - 8) % 2 != 0) return L2capSignalingError.InvalidLength;

        const count = @as(u8, @intCast((len - 8) / 2));
        if (count == 0 or count > 5) return L2capSignalingError.InvalidParameter;

        var req = CreditBasedConnReq{
            .identifier = raw[1],
            .spsm = std.mem.readInt(u16, raw[4..6], .little),
            .mtu = std.mem.readInt(u16, raw[6..8], .little),
            .mps = std.mem.readInt(u16, raw[8..10], .little),
            .initial_credits = std.mem.readInt(u16, raw[10..12], .little),
            .source_cid_count = count,
        };

        for (0..count) |i| {
            req.source_cids[i] = std.mem.readInt(u16, raw[12 + i * 2 ..][0..2], .little);
        }

        return req;
    }

    pub fn serialize(self: CreditBasedConnReq, dest: []u8) L2capSignalingError!usize {
        if (self.source_cid_count == 0 or self.source_cid_count > 5) return L2capSignalingError.InvalidParameter;
        const payload_len = 8 + @as(u16, self.source_cid_count) * 2;
        const total_len = 4 + payload_len;
        if (dest.len < total_len) return L2capSignalingError.BufferTooSmall;

        dest[0] = @intFromEnum(SignalingOpcode.credit_based_conn_req);
        dest[1] = self.identifier;
        std.mem.writeInt(u16, dest[2..4], payload_len, .little);
        std.mem.writeInt(u16, dest[4..6], self.spsm, .little);
        std.mem.writeInt(u16, dest[6..8], self.mtu, .little);
        std.mem.writeInt(u16, dest[8..10], self.mps, .little);
        std.mem.writeInt(u16, dest[10..12], self.initial_credits, .little);

        for (0..self.source_cid_count) |i| {
            std.mem.writeInt(u16, dest[12 + i * 2 ..][0..2], self.source_cids[i], .little);
        }

        return total_len;
    }
};

pub const CreditBasedConnRsp = struct {
    identifier: u8,
    mtu: u16,
    mps: u16,
    initial_credits: u16,
    result: EnhancedCreditConnResult,
    destination_cids: [5]u16 = [_]u16{0} ** 5,
    destination_cid_count: u8 = 0,

    pub fn parse(raw: []const u8) L2capSignalingError!CreditBasedConnRsp {
        if (raw.len < 12) return L2capSignalingError.BufferTooShort;
        if (raw[0] != @intFromEnum(SignalingOpcode.credit_based_conn_rsp)) return L2capSignalingError.InvalidOpcode;
        const len = std.mem.readInt(u16, raw[2..4], .little);
        if (len < 8 or (len - 8) % 2 != 0) return L2capSignalingError.InvalidLength;

        const count = @as(u8, @intCast((len - 8) / 2));
        if (count > 5) return L2capSignalingError.InvalidParameter;

        var rsp = CreditBasedConnRsp{
            .identifier = raw[1],
            .mtu = std.mem.readInt(u16, raw[4..6], .little),
            .mps = std.mem.readInt(u16, raw[6..8], .little),
            .initial_credits = std.mem.readInt(u16, raw[8..10], .little),
            .result = @enumFromInt(std.mem.readInt(u16, raw[10..12], .little)),
            .destination_cid_count = count,
        };

        for (0..count) |i| {
            rsp.destination_cids[i] = std.mem.readInt(u16, raw[12 + i * 2 ..][0..2], .little);
        }

        return rsp;
    }

    pub fn serialize(self: CreditBasedConnRsp, dest: []u8) L2capSignalingError!usize {
        if (self.destination_cid_count > 5) return L2capSignalingError.InvalidParameter;
        const payload_len = 8 + @as(u16, self.destination_cid_count) * 2;
        const total_len = 4 + payload_len;
        if (dest.len < total_len) return L2capSignalingError.BufferTooSmall;

        dest[0] = @intFromEnum(SignalingOpcode.credit_based_conn_rsp);
        dest[1] = self.identifier;
        std.mem.writeInt(u16, dest[2..4], payload_len, .little);
        std.mem.writeInt(u16, dest[4..6], self.mtu, .little);
        std.mem.writeInt(u16, dest[6..8], self.mps, .little);
        std.mem.writeInt(u16, dest[8..10], self.initial_credits, .little);
        std.mem.writeInt(u16, dest[10..12], @intFromEnum(self.result), .little);

        for (0..self.destination_cid_count) |i| {
            std.mem.writeInt(u16, dest[12 + i * 2 ..][0..2], self.destination_cids[i], .little);
        }

        return total_len;
    }
};

// -------------------------------------------------------------------------------------------------
// 7. Credit Based Reconfigure Request / Response (Opcodes 0x19, 0x1A - BT 5.2+)
// -------------------------------------------------------------------------------------------------

pub const CreditBasedReconfigureReq = struct {
    identifier: u8,
    mtu: u16,
    mps: u16,
    destination_cids: [5]u16 = [_]u16{0} ** 5,
    destination_cid_count: u8 = 0,

    pub fn parse(raw: []const u8) L2capSignalingError!CreditBasedReconfigureReq {
        if (raw.len < 10) return L2capSignalingError.BufferTooShort;
        if (raw[0] != @intFromEnum(SignalingOpcode.credit_based_reconfigure_req)) return L2capSignalingError.InvalidOpcode;
        const len = std.mem.readInt(u16, raw[2..4], .little);
        if (len < 6 or (len - 4) % 2 != 0) return L2capSignalingError.InvalidLength;

        const count = @as(u8, @intCast((len - 4) / 2));
        if (count == 0 or count > 5) return L2capSignalingError.InvalidParameter;

        var req = CreditBasedReconfigureReq{
            .identifier = raw[1],
            .mtu = std.mem.readInt(u16, raw[4..6], .little),
            .mps = std.mem.readInt(u16, raw[6..8], .little),
            .destination_cid_count = count,
        };

        for (0..count) |i| {
            req.destination_cids[i] = std.mem.readInt(u16, raw[8 + i * 2 ..][0..2], .little);
        }

        return req;
    }

    pub fn serialize(self: CreditBasedReconfigureReq, dest: []u8) L2capSignalingError!usize {
        if (self.destination_cid_count == 0 or self.destination_cid_count > 5) return L2capSignalingError.InvalidParameter;
        const payload_len = 4 + @as(u16, self.destination_cid_count) * 2;
        const total_len = 4 + payload_len;
        if (dest.len < total_len) return L2capSignalingError.BufferTooSmall;

        dest[0] = @intFromEnum(SignalingOpcode.credit_based_reconfigure_req);
        dest[1] = self.identifier;
        std.mem.writeInt(u16, dest[2..4], payload_len, .little);
        std.mem.writeInt(u16, dest[4..6], self.mtu, .little);
        std.mem.writeInt(u16, dest[6..8], self.mps, .little);

        for (0..self.destination_cid_count) |i| {
            std.mem.writeInt(u16, dest[8 + i * 2 ..][0..2], self.destination_cids[i], .little);
        }

        return total_len;
    }
};

pub const ReconfigureResult = enum(u16) {
    success = 0x0000,
    mtu_reduction_not_allowed = 0x0001,
    mps_reduction_not_allowed = 0x0002,
    destination_cid_invalid = 0x0003,
    unacceptable_parameters = 0x0004,
    _,
};

pub const CreditBasedReconfigureRsp = struct {
    identifier: u8,
    result: ReconfigureResult,

    pub const PDU_LEN: usize = 6;

    pub fn parse(raw: []const u8) L2capSignalingError!CreditBasedReconfigureRsp {
        if (raw.len < PDU_LEN) return L2capSignalingError.BufferTooShort;
        if (raw[0] != @intFromEnum(SignalingOpcode.credit_based_reconfigure_rsp)) return L2capSignalingError.InvalidOpcode;
        const len = std.mem.readInt(u16, raw[2..4], .little);
        if (len != 2) return L2capSignalingError.InvalidLength;

        return CreditBasedReconfigureRsp{
            .identifier = raw[1],
            .result = @enumFromInt(std.mem.readInt(u16, raw[4..6], .little)),
        };
    }

    pub fn serialize(self: CreditBasedReconfigureRsp, dest: []u8) L2capSignalingError!usize {
        if (dest.len < PDU_LEN) return L2capSignalingError.BufferTooSmall;
        dest[0] = @intFromEnum(SignalingOpcode.credit_based_reconfigure_rsp);
        dest[1] = self.identifier;
        std.mem.writeInt(u16, dest[2..4], 2, .little);
        std.mem.writeInt(u16, dest[4..6], @intFromEnum(self.result), .little);
        return PDU_LEN;
    }
};

// -------------------------------------------------------------------------------------------------
// Tagged Union: L2capSignalingPdu
// -------------------------------------------------------------------------------------------------

pub const L2capSignalingPdu = union(SignalingOpcode) {
    command_reject_rsp: CommandRejectRsp,
    disconnection_req: DisconnectionReq,
    disconnection_rsp: DisconnectionRsp,
    conn_param_update_req: ConnParamUpdateReq,
    conn_param_update_rsp: ConnParamUpdateRsp,
    le_credit_based_conn_req: LeCreditBasedConnReq,
    le_credit_based_conn_rsp: LeCreditBasedConnRsp,
    le_flow_control_credit: LeFlowControlCredit,
    credit_based_conn_req: CreditBasedConnReq,
    credit_based_conn_rsp: CreditBasedConnRsp,
    credit_based_reconfigure_req: CreditBasedReconfigureReq,
    credit_based_reconfigure_rsp: CreditBasedReconfigureRsp,

    pub fn parse(raw: []const u8) L2capSignalingError!L2capSignalingPdu {
        if (raw.len < SignalingHeader.HEADER_LEN) return L2capSignalingError.BufferTooShort;
        const opcode: SignalingOpcode = @enumFromInt(raw[0]);

        return switch (opcode) {
            .command_reject_rsp => .{ .command_reject_rsp = try CommandRejectRsp.parse(raw) },
            .disconnection_req => .{ .disconnection_req = try DisconnectionReq.parse(raw) },
            .disconnection_rsp => .{ .disconnection_rsp = try DisconnectionRsp.parse(raw) },
            .conn_param_update_req => .{ .conn_param_update_req = try ConnParamUpdateReq.parse(raw) },
            .conn_param_update_rsp => .{ .conn_param_update_rsp = try ConnParamUpdateRsp.parse(raw) },
            .le_credit_based_conn_req => .{ .le_credit_based_conn_req = try LeCreditBasedConnReq.parse(raw) },
            .le_credit_based_conn_rsp => .{ .le_credit_based_conn_rsp = try LeCreditBasedConnRsp.parse(raw) },
            .le_flow_control_credit => .{ .le_flow_control_credit = try LeFlowControlCredit.parse(raw) },
            .credit_based_conn_req => .{ .credit_based_conn_req = try CreditBasedConnReq.parse(raw) },
            .credit_based_conn_rsp => .{ .credit_based_conn_rsp = try CreditBasedConnRsp.parse(raw) },
            .credit_based_reconfigure_req => .{ .credit_based_reconfigure_req = try CreditBasedReconfigureReq.parse(raw) },
            .credit_based_reconfigure_rsp => .{ .credit_based_reconfigure_rsp = try CreditBasedReconfigureRsp.parse(raw) },
            _ => L2capSignalingError.InvalidOpcode,
        };
    }

    pub fn serialize(self: L2capSignalingPdu, dest: []u8) L2capSignalingError!usize {
        return switch (self) {
            .command_reject_rsp => |p| p.serialize(dest),
            .disconnection_req => |p| p.serialize(dest),
            .disconnection_rsp => |p| p.serialize(dest),
            .conn_param_update_req => |p| p.serialize(dest),
            .conn_param_update_rsp => |p| p.serialize(dest),
            .le_credit_based_conn_req => |p| p.serialize(dest),
            .le_credit_based_conn_rsp => |p| p.serialize(dest),
            .le_flow_control_credit => |p| p.serialize(dest),
            .credit_based_conn_req => |p| p.serialize(dest),
            .credit_based_conn_rsp => |p| p.serialize(dest),
            .credit_based_reconfigure_req => |p| p.serialize(dest),
            .credit_based_reconfigure_rsp => |p| p.serialize(dest),
        };
    }

    pub fn getIdentifier(self: L2capSignalingPdu) u8 {
        return switch (self) {
            inline else => |p| p.identifier,
        };
    }

    pub fn getOpcode(self: L2capSignalingPdu) SignalingOpcode {
        return self;
    }
};

// -------------------------------------------------------------------------------------------------
// Framing Helpers (L2CAP B-Frame encapsulation)
// -------------------------------------------------------------------------------------------------

/// Encapsulates a signaling PDU inside a standard 4-byte L2CAP B-frame header.
pub fn encodeFrame(cid: u16, pdu: L2capSignalingPdu, dest: []u8) L2capSignalingError!usize {
    if (dest.len < L2capHeader.HEADER_LEN) return L2capSignalingError.BufferTooSmall;
    const pdu_len = try pdu.serialize(dest[L2capHeader.HEADER_LEN..]);
    const hdr = L2capHeader{
        .length = @intCast(pdu_len),
        .cid = cid,
    };
    _ = try hdr.serialize(dest[0..L2capHeader.HEADER_LEN]);
    return L2capHeader.HEADER_LEN + pdu_len;
}

/// Decapsulates a standard 4-byte L2CAP B-frame header and parses the contained signaling PDU.
pub fn decodeFrame(raw: []const u8) L2capSignalingError!struct { header: L2capHeader, pdu: L2capSignalingPdu } {
    const hdr = try L2capHeader.parse(raw);
    if (raw.len < L2capHeader.HEADER_LEN + hdr.length) return L2capSignalingError.BufferTooShort;
    const pdu = try L2capSignalingPdu.parse(raw[L2capHeader.HEADER_LEN .. L2capHeader.HEADER_LEN + hdr.length]);
    return .{
        .header = hdr,
        .pdu = pdu,
    };
}

// =================================================================================================
// Unit Tests
// =================================================================================================

test "L2CAP Header serialize/parse" {
    var buf: [16]u8 = undefined;
    const hdr = L2capHeader{ .length = 24, .cid = CID_LE_SIGNALING };
    const len = try hdr.serialize(&buf);
    try std.testing.expectEqual(@as(usize, 4), len);

    const parsed = try L2capHeader.parse(buf[0..len]);
    try std.testing.expectEqual(@as(u16, 24), parsed.length);
    try std.testing.expectEqual(CID_LE_SIGNALING, parsed.cid);
}

test "ConnParamUpdate roundtrip" {
    var buf: [64]u8 = undefined;
    const req = ConnParamUpdateReq{
        .identifier = 0x01,
        .interval_min = 16, // 20ms
        .interval_max = 32, // 40ms
        .latency = 0,
        .timeout = 200, // 2000ms
    };

    const len = try req.serialize(&buf);
    try std.testing.expectEqual(@as(usize, 12), len);

    const parsed_pdu = try L2capSignalingPdu.parse(buf[0..len]);
    try std.testing.expect(parsed_pdu == .conn_param_update_req);
    try std.testing.expectEqual(@as(u8, 0x01), parsed_pdu.conn_param_update_req.identifier);
    try std.testing.expectEqual(@as(u16, 16), parsed_pdu.conn_param_update_req.interval_min);
    try std.testing.expectEqual(@as(u16, 32), parsed_pdu.conn_param_update_req.interval_max);
    try std.testing.expectEqual(@as(u16, 0), parsed_pdu.conn_param_update_req.latency);
    try std.testing.expectEqual(@as(u16, 200), parsed_pdu.conn_param_update_req.timeout);

    // Response
    const rsp = ConnParamUpdateRsp{
        .identifier = 0x01,
        .result = .accepted,
    };
    const rsp_len = try rsp.serialize(&buf);
    try std.testing.expectEqual(@as(usize, 6), rsp_len);

    const parsed_rsp = try L2capSignalingPdu.parse(buf[0..rsp_len]);
    try std.testing.expect(parsed_rsp == .conn_param_update_rsp);
    try std.testing.expectEqual(ConnParamUpdateResult.accepted, parsed_rsp.conn_param_update_rsp.result);
}

test "LeCreditBasedConn roundtrip" {
    var buf: [64]u8 = undefined;
    const req = LeCreditBasedConnReq{
        .identifier = 0x02,
        .spsm = 0x0027, // Object Transfer Service PSM
        .source_cid = 0x0041,
        .mtu = 512,
        .mps = 250,
        .initial_credits = 10,
    };

    const len = try req.serialize(&buf);
    try std.testing.expectEqual(@as(usize, 14), len);

    const parsed_req = try LeCreditBasedConnReq.parse(buf[0..len]);
    try std.testing.expectEqual(@as(u16, 0x0027), parsed_req.spsm);
    try std.testing.expectEqual(@as(u16, 0x0041), parsed_req.source_cid);
    try std.testing.expectEqual(@as(u16, 512), parsed_req.mtu);
    try std.testing.expectEqual(@as(u16, 250), parsed_req.mps);
    try std.testing.expectEqual(@as(u16, 10), parsed_req.initial_credits);

    const rsp = LeCreditBasedConnRsp{
        .identifier = 0x02,
        .destination_cid = 0x0042,
        .mtu = 512,
        .mps = 250,
        .initial_credits = 15,
        .result = .success,
    };
    const rsp_len = try rsp.serialize(&buf);
    try std.testing.expectEqual(@as(usize, 14), rsp_len);

    const parsed_rsp = try LeCreditBasedConnRsp.parse(buf[0..rsp_len]);
    try std.testing.expectEqual(LeCreditConnResult.success, parsed_rsp.result);
    try std.testing.expectEqual(@as(u16, 0x0042), parsed_rsp.destination_cid);
    try std.testing.expectEqual(@as(u16, 15), parsed_rsp.initial_credits);
}

test "DisconnectionReq/Rsp and FlowControlCredit roundtrip" {
    var buf: [64]u8 = undefined;

    // Disconnection Req
    const disconn_req = DisconnectionReq{
        .identifier = 0x03,
        .destination_cid = 0x0042,
        .source_cid = 0x0041,
    };
    const len1 = try disconn_req.serialize(&buf);
    try std.testing.expectEqual(@as(usize, 8), len1);

    const parsed_disconn = try DisconnectionReq.parse(buf[0..len1]);
    try std.testing.expectEqual(@as(u16, 0x0042), parsed_disconn.destination_cid);
    try std.testing.expectEqual(@as(u16, 0x0041), parsed_disconn.source_cid);

    // Flow Control Credit
    const credit = LeFlowControlCredit{
        .identifier = 0x04,
        .cid = 0x0042,
        .credits = 5,
    };
    const len2 = try credit.serialize(&buf);
    try std.testing.expectEqual(@as(usize, 8), len2);

    const parsed_credit = try LeFlowControlCredit.parse(buf[0..len2]);
    try std.testing.expectEqual(@as(u16, 0x0042), parsed_credit.cid);
    try std.testing.expectEqual(@as(u16, 5), parsed_credit.credits);
}

test "Enhanced Credit Based Connection (BT 5.2+)" {
    var buf: [128]u8 = undefined;

    var req = CreditBasedConnReq{
        .identifier = 0x05,
        .spsm = 0x0025,
        .mtu = 1024,
        .mps = 250,
        .initial_credits = 8,
        .source_cid_count = 3,
    };
    req.source_cids[0] = 0x0040;
    req.source_cids[1] = 0x0041;
    req.source_cids[2] = 0x0042;

    const len = try req.serialize(&buf);
    try std.testing.expectEqual(@as(usize, 4 + 8 + 6), len);

    const parsed_pdu = try L2capSignalingPdu.parse(buf[0..len]);
    try std.testing.expect(parsed_pdu == .credit_based_conn_req);
    try std.testing.expectEqual(@as(u8, 3), parsed_pdu.credit_based_conn_req.source_cid_count);
    try std.testing.expectEqual(@as(u16, 0x0040), parsed_pdu.credit_based_conn_req.source_cids[0]);
    try std.testing.expectEqual(@as(u16, 0x0041), parsed_pdu.credit_based_conn_req.source_cids[1]);
    try std.testing.expectEqual(@as(u16, 0x0042), parsed_pdu.credit_based_conn_req.source_cids[2]);
}

test "Full L2CAP Frame encode/decode" {
    var frame_buf: [128]u8 = undefined;

    const pdu = L2capSignalingPdu{
        .le_flow_control_credit = .{
            .identifier = 0x09,
            .cid = 0x0045,
            .credits = 100,
        },
    };

    const frame_len = try encodeFrame(CID_LE_SIGNALING, pdu, &frame_buf);
    try std.testing.expectEqual(@as(usize, 4 + 8), frame_len);

    const decoded = try decodeFrame(frame_buf[0..frame_len]);
    try std.testing.expectEqual(CID_LE_SIGNALING, decoded.header.cid);
    try std.testing.expectEqual(@as(u16, 8), decoded.header.length);
    try std.testing.expect(decoded.pdu == .le_flow_control_credit);
    try std.testing.expectEqual(@as(u16, 100), decoded.pdu.le_flow_control_credit.credits);
}
