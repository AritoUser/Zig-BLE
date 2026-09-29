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

pub const AF_BLUETOOTH: u16 = 31;
pub const BTPROTO_L2CAP: u32 = 0;

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
};

/// High-performance L2CAP Connection-Oriented Channel socket.
pub const L2capSocket = struct {
    fd: if (builtin.os.tag == .linux) std.posix.fd_t else i32,

    /// Opens an L2CAP socket.
    pub fn open(sock_type: SocketType) L2capError!L2capSocket {
        if (builtin.os.tag != .linux) {
            return L2capError.NotSupported;
        }

        const st: u32 = switch (sock_type) {
            .seqpacket => std.posix.SOCK.SEQPACKET,
            .stream => std.posix.SOCK.STREAM,
        };

        const fd = std.posix.socket(AF_BLUETOOTH, st, BTPROTO_L2CAP) catch {
            return L2capError.SocketCreationFailed;
        };

        return L2capSocket{ .fd = fd };
    }

    /// Closes the socket.
    pub fn close(self: *L2capSocket) void {
        if (builtin.os.tag == .linux) {
            std.posix.close(self.fd);
        }
    }

    /// Binds the socket to a local address and Protocol/Service Multiplexer (PSM).
    pub fn bind(self: *L2capSocket, local_addr: Address, psm: u16, addr_type: AddressType) L2capError!void {
        if (builtin.os.tag != .linux) return L2capError.NotSupported;

        var addr = sockaddr_l2{
            .l2_family = AF_BLUETOOTH,
            .l2_psm = std.mem.nativeToLittle(u16, psm),
            .l2_bdaddr = local_addr.bytes,
            .l2_cid = 0,
            .l2_bdaddr_type = if (addr_type == .public) 1 else 2,
        };

        const sock_addr: *const std.posix.sockaddr = @ptrCast(&addr);
        std.posix.bind(self.fd, sock_addr, @sizeOf(sockaddr_l2)) catch {
            return L2capError.BindFailed;
        };
    }

    /// Puts the socket into listening mode for incoming peripheral connections.
    pub fn listen(self: *L2capSocket, backlog: u31) L2capError!void {
        if (builtin.os.tag != .linux) return L2capError.NotSupported;

        std.posix.listen(self.fd, backlog) catch {
            return L2capError.ListenFailed;
        };
    }

    /// Connects to a remote peripheral's L2CAP PSM.
    pub fn connect(self: *L2capSocket, remote_addr: Address, psm: u16, addr_type: AddressType) L2capError!void {
        if (builtin.os.tag != .linux) return L2capError.NotSupported;

        var addr = sockaddr_l2{
            .l2_family = AF_BLUETOOTH,
            .l2_psm = std.mem.nativeToLittle(u16, psm),
            // BD_ADDR in Linux kernel is stored little-endian (reverse of human-readable MAC)
            .l2_bdaddr = [6]u8{
                remote_addr.bytes[5],
                remote_addr.bytes[4],
                remote_addr.bytes[3],
                remote_addr.bytes[2],
                remote_addr.bytes[1],
                remote_addr.bytes[0],
            },
            .l2_cid = 0,
            .l2_bdaddr_type = if (addr_type == .public) 1 else 2,
        };

        const sock_addr: *const std.posix.sockaddr = @ptrCast(&addr);
        std.posix.connect(self.fd, sock_addr, @sizeOf(sockaddr_l2)) catch {
            return L2capError.ConnectFailed;
        };
    }

    /// Reads data from the L2CAP stream into `buf`.
    pub fn read(self: *L2capSocket, buf: []u8) L2capError!usize {
        if (builtin.os.tag != .linux) return L2capError.NotSupported;

        const n = std.posix.read(self.fd, buf) catch |err| {
            if (err == error.WouldBlock) return 0;
            return L2capError.ReadFailed;
        };
        if (n == 0) return L2capError.ConnectionClosed;
        return n;
    }

    /// Writes data to the L2CAP stream.
    pub fn write(self: *L2capSocket, data: []const u8) L2capError!usize {
        if (builtin.os.tag != .linux) return L2capError.NotSupported;

        return std.posix.write(self.fd, data) catch {
            return L2capError.WriteFailed;
        };
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
