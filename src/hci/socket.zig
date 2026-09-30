//! Native Linux Raw HCI Socket implementation (100% Pure Zig, 0 C dependencies).
//! Communicates directly with the Bluetooth Controller via Linux AF_BLUETOOTH and BTPROTO_HCI.
//! Operates completely independent of BlueZ bluetoothd and D-Bus.

const std = @import("std");
const builtin = @import("builtin");
const constants = @import("constants.zig");
const HciFilter = @import("filter.zig").HciFilter;
const HciEvent = @import("events.zig").HciEvent;

pub const HciError = error{
    NotSupported,
    SocketCreationFailed,
    BindFailed,
    SetFilterFailed,
    SendFailed,
    ReadFailed,
    BufferTooSmall,
    Timeout,
    CommandFailed,
};

pub const HciSocket = struct {
    fd: if (builtin.os.tag == .linux) std.posix.fd_t else i32 = -1,
    device_index: u16 = 0,
    channel: u16 = constants.HCI_CHANNEL_RAW,

    /// Opens and binds a raw HCI socket to a Bluetooth controller (e.g. hci0 -> device_index = 0).
    pub fn open(device_index: u16, channel: u16) HciError!HciSocket {
        if (builtin.os.tag != .linux) {
            return HciError.NotSupported;
        }

        const rc = std.posix.system.socket(
            constants.AF_BLUETOOTH,
            std.posix.SOCK.RAW | std.posix.SOCK.CLOEXEC,
            constants.BTPROTO_HCI,
        );
        if (std.posix.errno(rc) != .SUCCESS) {
            return HciError.SocketCreationFailed;
        }

        const fd: std.posix.fd_t = @intCast(rc);
        errdefer _ = std.posix.system.close(fd);

        var addr = constants.sockaddr_hci{
            .hci_family = constants.AF_BLUETOOTH,
            .hci_dev = device_index,
            .hci_channel = channel,
        };

        const bind_rc = std.posix.system.bind(fd, @ptrCast(&addr), @sizeOf(constants.sockaddr_hci));
        if (std.posix.errno(bind_rc) != .SUCCESS) {
            return HciError.BindFailed;
        }

        return HciSocket{
            .fd = fd,
            .device_index = device_index,
            .channel = channel,
        };
    }

    /// Closes the HCI socket.
    pub fn close(self: *HciSocket) void {
        if (builtin.os.tag == .linux) {
            if (self.fd >= 0) {
                _ = std.posix.system.close(self.fd);
                self.fd = -1;
            }
        }
    }

    /// Sets the socket-level HCI event and packet filter (SOL_HCI, HCI_FILTER).
    pub fn setFilter(self: *HciSocket, filter: HciFilter) HciError!void {
        if (builtin.os.tag != .linux) return HciError.NotSupported;

        const rc = std.posix.system.setsockopt(
            self.fd,
            constants.SOL_HCI,
            constants.HCI_FILTER,
            @ptrCast(&filter),
            @sizeOf(HciFilter),
        );
        if (std.posix.errno(rc) != .SUCCESS) {
            return HciError.SetFilterFailed;
        }
    }

    /// Transmits a raw HCI packet (e.g. HCI Command) directly to the Bluetooth controller.
    pub fn send(self: *HciSocket, packet: []const u8) HciError!void {
        if (builtin.os.tag != .linux) return HciError.NotSupported;

        const rc = std.posix.system.write(self.fd, packet.ptr, packet.len);
        if (std.posix.errno(rc) != .SUCCESS or rc != packet.len) {
            return HciError.SendFailed;
        }
    }

    /// Reads a raw HCI packet from the controller into `buf`.
    pub fn readPacket(self: *HciSocket, buf: []u8) HciError!usize {
        if (builtin.os.tag != .linux) return HciError.NotSupported;

        const rc = std.posix.system.read(self.fd, buf.ptr, buf.len);
        const err = std.posix.errno(rc);
        if (err == .AGAIN) return 0;
        if (err != .SUCCESS) return HciError.ReadFailed;
        return @intCast(rc);
    }

    /// Polls the socket for readable packets with a timeout in milliseconds.
    pub fn poll(self: *HciSocket, timeout_ms: c_int) usize {
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
};

test "HciSocket: non-linux mock check" {
    if (builtin.os.tag != .linux) {
        var sock = HciSocket{};
        try std.testing.expectError(HciError.NotSupported, HciSocket.open(0, 0));
        sock.close();
    }
}
