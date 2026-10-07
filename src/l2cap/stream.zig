//! # L2CAP High-Level Connection-Oriented Channels (CoC) API
//!
//! Conforms to Bluetooth Core Specification Vol 3, Part A (L2CAP).
//! Provides high-level stream and listener abstractions for high-throughput
//! LE Credit-Based Channels (e.g. Galaxy Watch Ultra `watch-wire`, PSM 0x1001,
//! or custom wearable continuous telemetry streams).
//!
//! Fully zero-allocation hot paths, supporting native Linux `AF_BLUETOOTH`
//! sockets as well as deterministic in-memory mock streams for CI testing.

const std = @import("std");
const builtin = @import("builtin");
const core_types = @import("../core/types.zig");
const Address = core_types.Address;
const socket = @import("socket.zig");
const SecurityLevel = socket.SecurityLevel;
const L2capError = socket.L2capError;

/// Configuration options for an L2CAP CoC connection.
pub const L2capConfig = struct {
    /// Maximum Transmission Unit (MTU) advertised to peer.
    mtu: u16 = 672,
    /// Maximum PDU payload Size (MPS) for packet segmentation.
    mps: u16 = 251,
    /// Initial flow control credits.
    credits: u16 = 10,
    /// Security level required for channel establishment.
    security: SecurityLevel = .low,
};

/// Type of underlying transport powering an `L2capStream`.
pub const StreamBackend = union(enum) {
    native_fd: std.posix.fd_t,
    mock_channel: *MockChannel,
};

/// An active, bi-directional L2CAP Connection-Oriented Channel stream.
pub const L2capStream = struct {
    backend: StreamBackend,
    mtu: u16,
    mps: u16,
    is_closed: bool = false,

    /// Reads incoming SDU data from the channel into `buf`.
    /// Returns the number of bytes read.
    pub fn read(self: *L2capStream, buf: []u8) !usize {
        if (self.is_closed) return error.ConnectionClosed;
        switch (self.backend) {
            .native_fd => |fd| {
                if (builtin.os.tag == .linux) {
                    return std.posix.read(fd, buf) catch |err| switch (err) {
                        error.ConnectionResetByPeer => error.ConnectionClosed,
                        else => err,
                    };
                }
                return error.NotSupported;
            },
            .mock_channel => |chan| {
                return chan.read(buf);
            },
        }
    }

    /// Writes data to the channel. Automatically segmented if larger than MPS.
    pub fn write(self: *L2capStream, data: []const u8) !usize {
        if (self.is_closed) return error.ConnectionClosed;
        if (data.len > self.mtu) return error.MessageTooLarge;

        switch (self.backend) {
            .native_fd => |fd| {
                if (builtin.os.tag == .linux) {
                    const rc = std.posix.system.write(fd, data.ptr, data.len);
                    if (std.posix.errno(rc) != .SUCCESS) return error.WriteFailed;
                    return @intCast(rc);
                }
                return error.NotSupported;
            },
            .mock_channel => |chan| {
                return chan.write(data);
            },
        }
    }

    /// Closes the channel and releases underlying file descriptors / buffers.
    pub fn close(self: *L2capStream) void {
        if (self.is_closed) return;
        self.is_closed = true;
        switch (self.backend) {
            .native_fd => |fd| {
                if (builtin.os.tag == .linux) {
                    _ = std.posix.system.close(fd);
                }
            },
            .mock_channel => |chan| {
                chan.close();
            },
        }
    }

    pub inline fn getMtu(self: *const L2capStream) u16 {
        return self.mtu;
    }

    pub inline fn getMps(self: *const L2capStream) u16 {
        return self.mps;
    }
};

/// Server-side listener accepting incoming L2CAP CoC connections on a specific PSM.
pub const L2capListener = struct {
    backend: union(enum) {
        native_sock: socket.L2capSocket,
        mock_listener: *MockListener,
    },
    psm: u16,
    config: L2capConfig,

    pub fn accept(self: *L2capListener) !L2capStream {
        switch (self.backend) {
            .native_sock => |*sock| {
                if (builtin.os.tag == .linux) {
                    const conn = try sock.accept();
                    return L2capStream{
                        .backend = .{ .native_fd = conn.socket.fd },
                        .mtu = self.config.mtu,
                        .mps = self.config.mps,
                    };
                }
                return error.NotSupported;
            },
            .mock_listener => |mock| {
                return mock.accept();
            },
        }
    }

    pub fn close(self: *L2capListener) void {
        switch (self.backend) {
            .native_sock => |*sock| sock.close(),
            .mock_listener => |mock| mock.close(),
        }
    }
};

/// Connects an L2CAP CoC client to a remote peer on the given PSM.
pub fn connectL2cap(addr: Address, psm: u16, config: L2capConfig) !L2capStream {
    if (builtin.os.tag == .linux) {
        const sock = try socket.L2capSocket.connectLe(addr, psm, .public);
        return L2capStream{
            .backend = .{ .native_fd = sock.fd },
            .mtu = config.mtu,
            .mps = config.mps,
        };
    }
    return error.NotSupported;
}

/// Listens for incoming L2CAP CoC connections on a given PSM.
pub fn listenL2cap(psm: u16, config: L2capConfig) !L2capListener {
    if (builtin.os.tag == .linux) {
        var sock = try socket.L2capSocket.open(.seqpacket);
        errdefer sock.close();

        const any_addr = Address{ .bytes = [_]u8{0} ** 6 };
        try sock.bind(any_addr, psm, .public);
        try sock.listen(4);

        return L2capListener{
            .backend = .{ .native_sock = sock },
            .psm = psm,
            .config = config,
        };
    }
    return error.NotSupported;
}

// ============================================================================
// In-Memory Mock Stream & Listener for CI and Deterministic Testing
// ============================================================================

pub const MockChannel = struct {
    buffer: [4096]u8 = undefined,
    head: usize = 0,
    tail: usize = 0,
    is_closed: bool = false,
    peer: ?*MockChannel = null,

    pub fn read(self: *MockChannel, buf: []u8) !usize {
        if (self.is_closed and self.head == self.tail) return error.ConnectionClosed;
        const available = self.tail - self.head;
        if (available == 0) return 0;
        const to_read = @min(available, buf.len);
        @memcpy(buf[0..to_read], self.buffer[self.head .. self.head + to_read]);
        self.head += to_read;
        if (self.head == self.tail) {
            self.head = 0;
            self.tail = 0;
        }
        return to_read;
    }

    pub fn write(self: *MockChannel, data: []const u8) !usize {
        const p = self.peer orelse return error.ConnectionClosed;
        if (p.is_closed) return error.ConnectionClosed;
        const space = p.buffer.len - p.tail;
        if (space < data.len) return error.BufferTooSmall;
        @memcpy(p.buffer[p.tail .. p.tail + data.len], data);
        p.tail += data.len;
        return data.len;
    }

    pub fn close(self: *MockChannel) void {
        self.is_closed = true;
        if (self.peer) |p| p.is_closed = true;
    }
};

pub const MockListener = struct {
    pending_stream: ?L2capStream = null,
    is_closed: bool = false,

    pub fn accept(self: *MockListener) !L2capStream {
        if (self.is_closed) return error.ConnectionClosed;
        if (self.pending_stream) |st| {
            self.pending_stream = null;
            return st;
        }
        return error.WouldBlock;
    }

    pub fn close(self: *MockListener) void {
        self.is_closed = true;
    }
};

/// Creates a simulated in-memory L2CAP stream pair for testing without hardware.
pub fn createMockStreamPair(chan_a: *MockChannel, chan_b: *MockChannel, mtu: u16, mps: u16) struct { client: L2capStream, server: L2capStream } {
    chan_a.* = .{};
    chan_b.* = .{};
    chan_a.peer = chan_b;
    chan_b.peer = chan_a;

    return .{
        .client = L2capStream{
            .backend = .{ .mock_channel = chan_a },
            .mtu = mtu,
            .mps = mps,
        },
        .server = L2capStream{
            .backend = .{ .mock_channel = chan_b },
            .mtu = mtu,
            .mps = mps,
        },
    };
}

test "MockChannel bi-directional streaming test" {
    var chan_a: MockChannel = .{};
    var chan_b: MockChannel = .{};
    var pair = createMockStreamPair(&chan_a, &chan_b, 512, 251);

    // Client -> Server
    const msg = "GalaxyWatch_100Hz_PPG_Stream";
    _ = try pair.client.write(msg);

    var rx_buf: [64]u8 = undefined;
    const n = try pair.server.read(&rx_buf);
    try std.testing.expectEqualStrings(msg, rx_buf[0..n]);

    // Server -> Client
    const ack = "ACK_FRAME_01";
    _ = try pair.server.write(ack);
    const n_ack = try pair.client.read(&rx_buf);
    try std.testing.expectEqualStrings(ack, rx_buf[0..n_ack]);

    pair.client.close();
    try std.testing.expectError(error.ConnectionClosed, pair.server.write("after_close"));
}
