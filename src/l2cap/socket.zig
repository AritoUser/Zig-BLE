//! # L2CAP Connection-Oriented Channels (CoC)
//!
//! Provides direct, high-throughput credit-based streaming channels over BLE L2CAP,
//! bypassing GATT and ATT protocol overhead.
//!
//! Conforms to Bluetooth Core Specification (v5.4 / v6.0, Vol 3, Part A)
//! and the Linux Kernel `AF_BLUETOOTH` subsystem.

const std = @import("std");
const builtin = @import("builtin");
const types = @import("../core/types.zig");
const Address = types.Address;
const AddressType = types.AddressType;

// Linux AF_BLUETOOTH and protocol constants (net/bluetooth/bluetooth.h, l2cap.h)
pub const AF_BLUETOOTH: u16 = 31;
pub const BTPROTO_L2CAP: u32 = 0;
pub const SOL_BLUETOOTH: u32 = 274;
pub const SOL_L2CAP: u32 = 0;

// Socket options
pub const BT_SECURITY: u32 = 4;
pub const BT_DEFER_SETUP: u32 = 7;
pub const BT_FLT_DEV_NAME: u32 = 8;
pub const BT_PHY: u32 = 10;
pub const BT_MODE: u32 = 11;

pub const L2CAP_OPTIONS: u32 = 1;
pub const L2CAP_CONNINFO: u32 = 2;
pub const L2CAP_LM: u32 = 3;

/// Bluetooth Security Levels (BT_SECURITY)
pub const SecurityLevel = enum(u8) {
    sdp = 0,
    low = 1,
    medium = 2,
    high = 3,
    fips = 4,

    pub fn toString(self: SecurityLevel) []const u8 {
        return switch (self) {
            .sdp => "SDP",
            .low => "Low (No authentication / encryption)",
            .medium => "Medium (Unauthenticated encryption)",
            .high => "High (Authenticated encryption)",
            .fips => "FIPS (Secure Connections only)",
        };
    }
};

/// Linux Kernel bt_security layout
pub const bt_security = extern struct {
    level: u8,
    key_size: u8 = 0,
};

/// Linux Kernel l2cap_options layout
pub const l2cap_options = extern struct {
    omtu: u16 = 0,
    imtu: u16 = 0,
    flush_to: u16 = 0,
    mode: u8 = 0,
    fcs: u8 = 0,
    max_tx: u8 = 0,
    txwin_size: u16 = 0,
};

/// Linux Kernel l2cap_conninfo layout
pub const l2cap_conninfo = extern struct {
    hci_handle: u16 = 0,
    dev_class: [3]u8 = [_]u8{0} ** 3,
};

/// Linux Kernel sockaddr_l2 layout (include/net/bluetooth/l2cap.h)
pub const sockaddr_l2 = extern struct {
    l2_family: u16 = AF_BLUETOOTH,
    l2_psm: u16 = 0,
    l2_bdaddr: [6]u8 = [_]u8{0} ** 6,
    l2_cid: u16 = 0,
    l2_bdaddr_type: u8 = 1, // 1 = BDADDR_LE_PUBLIC, 2 = BDADDR_LE_RANDOM
    _pad: u8 = 0,
};

pub const SocketType = enum {
    /// Sequenced packet socket (preserves packet boundaries, standard for BLE L2CAP CoC).
    seqpacket,
    /// Stream socket.
    stream,
};

pub const L2capError = error{
    NotSupported,
    SocketCreationFailed,
    BindFailed,
    ListenFailed,
    ConnectFailed,
    AcceptFailed,
    ReadFailed,
    WriteFailed,
    ConnectionClosed,
    SecurityFailed,
    SocketOptionFailed,
    AddressResolutionFailed,
};

/// Result of an accepted inbound L2CAP connection.
pub const AcceptedConnection = struct {
    socket: L2capSocket,
    peer_address: Address,
    peer_address_type: AddressType,
};

/// Converts high-level big-endian Address to Linux kernel little-endian BD_ADDR.
pub fn toKernelBdAddr(addr: Address) [6]u8 {
    return [6]u8{
        addr.bytes[5],
        addr.bytes[4],
        addr.bytes[3],
        addr.bytes[2],
        addr.bytes[1],
        addr.bytes[0],
    };
}

/// Converts Linux kernel little-endian BD_ADDR to high-level big-endian Address.
pub fn fromKernelBdAddr(bdaddr: [6]u8) Address {
    return Address{
        .bytes = [6]u8{
            bdaddr[5],
            bdaddr[4],
            bdaddr[3],
            bdaddr[2],
            bdaddr[1],
            bdaddr[0],
        },
    };
}

/// High-performance L2CAP Connection-Oriented Channel socket.
pub const L2capSocket = struct {
    fd: if (builtin.os.tag == .linux) std.posix.fd_t else i32 = -1,

    /// Opens an L2CAP socket.
    pub fn open(sock_type: SocketType) L2capError!L2capSocket {
        if (builtin.os.tag != .linux) {
            return L2capError.NotSupported;
        }

        const st: u32 = switch (sock_type) {
            .seqpacket => std.posix.SOCK.SEQPACKET | std.posix.SOCK.CLOEXEC,
            .stream => std.posix.SOCK.STREAM | std.posix.SOCK.CLOEXEC,
        };

        const rc = std.posix.system.socket(AF_BLUETOOTH, st, BTPROTO_L2CAP);
        if (std.posix.errno(rc) != .SUCCESS) {
            return L2capError.SocketCreationFailed;
        }

        return L2capSocket{ .fd = @intCast(rc) };
    }

    /// Closes the socket.
    pub fn close(self: *L2capSocket) void {
        if (builtin.os.tag == .linux) {
            if (self.fd >= 0) {
                _ = std.posix.system.close(self.fd);
                self.fd = -1;
            }
        }
    }

    /// Binds the socket to a local address and Protocol/Service Multiplexer (PSM).
    pub fn bind(self: *L2capSocket, local_addr: Address, psm: u16, addr_type: AddressType) L2capError!void {
        if (builtin.os.tag != .linux) return L2capError.NotSupported;

        var addr = sockaddr_l2{
            .l2_family = AF_BLUETOOTH,
            .l2_psm = std.mem.nativeToLittle(u16, psm),
            .l2_bdaddr = toKernelBdAddr(local_addr),
            .l2_cid = 0,
            .l2_bdaddr_type = if (addr_type == .public) 1 else 2,
        };

        const rc = std.posix.system.bind(self.fd, @ptrCast(&addr), @sizeOf(sockaddr_l2));
        if (std.posix.errno(rc) != .SUCCESS) {
            return L2capError.BindFailed;
        }
    }

    /// Puts the socket into listening mode for incoming peripheral connections.
    pub fn listen(self: *L2capSocket, backlog: u31) L2capError!void {
        if (builtin.os.tag != .linux) return L2capError.NotSupported;

        const rc = std.posix.system.listen(self.fd, backlog);
        if (std.posix.errno(rc) != .SUCCESS) {
            return L2capError.ListenFailed;
        }
    }

    /// Accepts an incoming connection from a peer peripheral or central.
    pub fn accept(self: *L2capSocket) L2capError!AcceptedConnection {
        if (builtin.os.tag != .linux) return L2capError.NotSupported;

        var client_addr: sockaddr_l2 = std.mem.zeroes(sockaddr_l2);
        var addr_len: std.posix.socklen_t = @sizeOf(sockaddr_l2);
        const rc = std.posix.system.accept(self.fd, @ptrCast(&client_addr), &addr_len);
        if (std.posix.errno(rc) != .SUCCESS) {
            return L2capError.AcceptFailed;
        }

        return AcceptedConnection{
            .socket = L2capSocket{ .fd = @intCast(rc) },
            .peer_address = fromKernelBdAddr(client_addr.l2_bdaddr),
            .peer_address_type = if (client_addr.l2_bdaddr_type == 2) .random else .public,
        };
    }

    /// Connects to a remote peripheral's L2CAP PSM.
    pub fn connect(self: *L2capSocket, remote_addr: Address, psm: u16, addr_type: AddressType) L2capError!void {
        if (builtin.os.tag != .linux) return L2capError.NotSupported;

        var addr = sockaddr_l2{
            .l2_family = AF_BLUETOOTH,
            .l2_psm = std.mem.nativeToLittle(u16, psm),
            .l2_bdaddr = toKernelBdAddr(remote_addr),
            .l2_cid = 0,
            .l2_bdaddr_type = if (addr_type == .public) 1 else 2,
        };

        const rc = std.posix.system.connect(self.fd, @ptrCast(&addr), @sizeOf(sockaddr_l2));
        if (std.posix.errno(rc) != .SUCCESS) {
            return L2capError.ConnectFailed;
        }
    }

    /// Convenience helper: opens a seqpacket L2CAP socket and connects to the remote address.
    pub fn connectLe(remote_addr: Address, psm: u16, addr_type: AddressType) L2capError!L2capSocket {
        if (builtin.os.tag != .linux) return L2capError.NotSupported;
        var sock = try open(.seqpacket);
        errdefer sock.close();
        try sock.connect(remote_addr, psm, addr_type);
        return sock;
    }

    /// Retrieves the remote peer Bluetooth address.
    pub fn getPeerAddress(self: *L2capSocket) L2capError!Address {
        if (builtin.os.tag != .linux) return L2capError.NotSupported;

        var addr: sockaddr_l2 = std.mem.zeroes(sockaddr_l2);
        var len: std.posix.socklen_t = @sizeOf(sockaddr_l2);
        const rc = std.posix.system.getpeername(self.fd, @ptrCast(&addr), &len);
        if (std.posix.errno(rc) != .SUCCESS) return L2capError.AddressResolutionFailed;
        return fromKernelBdAddr(addr.l2_bdaddr);
    }

    /// Retrieves the locally bound Bluetooth adapter address.
    pub fn getLocalAddress(self: *L2capSocket) L2capError!Address {
        if (builtin.os.tag != .linux) return L2capError.NotSupported;

        var addr: sockaddr_l2 = std.mem.zeroes(sockaddr_l2);
        var len: std.posix.socklen_t = @sizeOf(sockaddr_l2);
        const rc = std.posix.system.getsockname(self.fd, @ptrCast(&addr), &len);
        if (std.posix.errno(rc) != .SUCCESS) return L2capError.AddressResolutionFailed;
        return fromKernelBdAddr(addr.l2_bdaddr);
    }

    /// Configures the Bluetooth security level on this L2CAP socket.
    pub fn setSecurityLevel(self: *L2capSocket, level: SecurityLevel, key_size: u8) L2capError!void {
        if (builtin.os.tag != .linux) return L2capError.NotSupported;

        var sec = bt_security{
            .level = @intFromEnum(level),
            .key_size = key_size,
        };
        const rc = std.posix.system.setsockopt(
            self.fd,
            SOL_BLUETOOTH,
            BT_SECURITY,
            @ptrCast(&sec),
            @sizeOf(bt_security),
        );
        if (std.posix.errno(rc) != .SUCCESS) {
            return L2capError.SecurityFailed;
        }
    }

    /// Queries the current Bluetooth security level of this socket.
    pub fn getSecurityLevel(self: *L2capSocket) L2capError!SecurityLevel {
        if (builtin.os.tag != .linux) return L2capError.NotSupported;

        var sec: bt_security = std.mem.zeroes(bt_security);
        var len: std.posix.socklen_t = @sizeOf(bt_security);
        const rc = std.posix.system.getsockopt(
            self.fd,
            SOL_BLUETOOTH,
            BT_SECURITY,
            @ptrCast(&sec),
            &len,
        );
        if (std.posix.errno(rc) != .SUCCESS) {
            return L2capError.SecurityFailed;
        }
        return std.meta.intToEnum(SecurityLevel, sec.level) catch return L2capError.SecurityFailed;
    }

    /// Queries L2CAP parameters (omtu, imtu, mode, etc.).
    pub fn getOptions(self: *L2capSocket) L2capError!l2cap_options {
        if (builtin.os.tag != .linux) return L2capError.NotSupported;

        var opts: l2cap_options = std.mem.zeroes(l2cap_options);
        var len: std.posix.socklen_t = @sizeOf(l2cap_options);
        const rc = std.posix.system.getsockopt(
            self.fd,
            SOL_L2CAP,
            L2CAP_OPTIONS,
            @ptrCast(&opts),
            &len,
        );
        if (std.posix.errno(rc) != .SUCCESS) {
            return L2capError.SocketOptionFailed;
        }
        return opts;
    }

    /// Configures L2CAP parameters (e.g. desired incoming MTU).
    pub fn setOptions(self: *L2capSocket, opts: l2cap_options) L2capError!void {
        if (builtin.os.tag != .linux) return L2capError.NotSupported;

        const rc = std.posix.system.setsockopt(
            self.fd,
            SOL_L2CAP,
            L2CAP_OPTIONS,
            @ptrCast(&opts),
            @sizeOf(l2cap_options),
        );
        if (std.posix.errno(rc) != .SUCCESS) {
            return L2capError.SocketOptionFailed;
        }
    }

    /// Sets non-blocking I/O mode on the socket.
    pub fn setNonBlocking(self: *L2capSocket, non_blocking: bool) L2capError!void {
        if (builtin.os.tag != .linux) return L2capError.NotSupported;

        const rc = std.posix.system.fcntl(self.fd, std.posix.F.GETFL, 0);
        if (std.posix.errno(rc) != .SUCCESS) return L2capError.SocketOptionFailed;
        const flags: usize = @intCast(rc);
        const new_flags = if (non_blocking)
            flags | std.posix.O.NONBLOCK
        else
            flags & ~@as(usize, std.posix.O.NONBLOCK);
        const set_rc = std.posix.system.fcntl(self.fd, std.posix.F.SETFL, new_flags);
        if (std.posix.errno(set_rc) != .SUCCESS) return L2capError.SocketOptionFailed;
    }

    /// Polls the socket for readable packets with a timeout in milliseconds.
    pub fn poll(self: *L2capSocket, timeout_ms: c_int) usize {
        if (builtin.os.tag != .linux) return 0;

        var pfd = [_]std.posix.pollfd{.{
            .fd = self.fd,
            .events = std.posix.POLL.IN,
            .revents = 0,
        }};

        const rc = std.posix.system.poll(&pfd, 1, timeout_ms);
        if (rc > 0 and (pfd[0].revents & std.posix.POLL.IN) != 0) {
            return 1;
        }
        return 0;
    }

    /// Reads data from the L2CAP stream into `buf`.
    pub fn read(self: *L2capSocket, buf: []u8) L2capError!usize {
        if (builtin.os.tag != .linux) return L2capError.NotSupported;

        const rc = std.posix.system.read(self.fd, buf.ptr, buf.len);
        const err = std.posix.errno(rc);
        if (err == .AGAIN or err == .WOULDBLOCK) return 0;
        if (err != .SUCCESS) return L2capError.ReadFailed;
        if (rc == 0) return L2capError.ConnectionClosed;
        return @intCast(rc);
    }

    /// Writes data to the L2CAP stream.
    pub fn write(self: *L2capSocket, data: []const u8) L2capError!usize {
        if (builtin.os.tag != .linux) return L2capError.NotSupported;

        const rc = std.posix.system.write(self.fd, data.ptr, data.len);
        if (std.posix.errno(rc) != .SUCCESS) {
            return L2capError.WriteFailed;
        }
        return @intCast(rc);
    }

    /// Writes all bytes in `data`, handling partial writes.
    pub fn writeAll(self: *L2capSocket, data: []const u8) L2capError!void {
        var written: usize = 0;
        while (written < data.len) {
            const n = try self.write(data[written..]);
            if (n == 0) return L2capError.ConnectionClosed;
            written += n;
        }
    }
};

// ============================================================================
// Unit Tests
// ============================================================================

test "sockaddr_l2 memory layout and size" {
    try std.testing.expectEqual(@as(usize, 14), @sizeOf(sockaddr_l2));
    const s = sockaddr_l2{
        .l2_family = AF_BLUETOOTH,
        .l2_psm = 0x1001,
        .l2_bdaddr = [_]u8{ 0x11, 0x22, 0x33, 0x44, 0x55, 0x66 },
        .l2_cid = 0x0040,
        .l2_bdaddr_type = 2,
    };
    try std.testing.expectEqual(@as(u16, 31), s.l2_family);
    try std.testing.expectEqual(@as(u16, 0x1001), s.l2_psm);
    try std.testing.expectEqual(@as(u8, 2), s.l2_bdaddr_type);
}

test "bt_security and l2cap_options struct layout" {
    try std.testing.expectEqual(@as(usize, 2), @sizeOf(bt_security));
    try std.testing.expectEqual(@as(usize, 12), @sizeOf(l2cap_options));

    const sec = bt_security{ .level = 3, .key_size = 16 };
    try std.testing.expectEqual(@as(u8, 3), sec.level);
    try std.testing.expectEqual(@as(u8, 16), sec.key_size);

    const opts = l2cap_options{ .omtu = 512, .imtu = 512, .mode = 0 };
    try std.testing.expectEqual(@as(u16, 512), opts.omtu);
    try std.testing.expectEqual(@as(u16, 512), opts.imtu);
}

test "kernel bd_addr endianness conversion" {
    const addr = try Address.parse("11:22:33:44:55:66");
    const kernel_bytes = toKernelBdAddr(addr);
    try std.testing.expectEqualSlices(u8, &[_]u8{ 0x66, 0x55, 0x44, 0x33, 0x22, 0x11 }, &kernel_bytes);

    const converted_back = fromKernelBdAddr(kernel_bytes);
    try std.testing.expect(addr.eql(converted_back));
}

test "L2capSocket: non-linux mock check" {
    if (builtin.os.tag != .linux) {
        var sock = L2capSocket{};
        try std.testing.expectError(L2capError.NotSupported, L2capSocket.open(.seqpacket));
        sock.close();
    }
}
