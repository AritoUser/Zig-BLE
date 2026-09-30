//! Native Linux UNIX domain socket transport for D-Bus
//! 100% pure Zig via std.posix and Linux syscalls (0 C dependencies)
//! Full support for UNIX file descriptor passing (SCM_RIGHTS) and D-Bus address resolution.

const std = @import("std");
const builtin = @import("builtin");

/// Reads an environment variable directly from /proc/self/environ without libc or heap allocations.
pub fn getEnvVar(name: []const u8, buf: []u8) ?[]const u8 {
    if (builtin.os.tag != .linux) return null;
    const rc = std.posix.system.open("/proc/self/environ", @as(std.posix.O, @bitCast(@as(u32, 0))), 0);
    const err = std.posix.errno(rc);
    if (err != .SUCCESS) return null;
    const fd: std.posix.fd_t = @intCast(rc);
    defer _ = std.posix.system.close(fd);

    var env_buf: [4096]u8 = undefined;
    const n_rc = std.posix.system.read(fd, &env_buf, env_buf.len);
    if (n_rc <= 0) return null;
    const bytes = env_buf[0..@intCast(n_rc)];

    var iter = std.mem.splitScalar(u8, bytes, 0);
    while (iter.next()) |entry| {
        if (entry.len == 0) continue;
        if (std.mem.startsWith(u8, entry, name) and entry.len > name.len and entry[name.len] == '=') {
            const val = entry[name.len + 1 ..];
            if (val.len > buf.len) return null;
            @memcpy(buf[0..val.len], val);
            return buf[0..val.len];
        }
    }
    return null;
}

/// Extracts path from a D-Bus address string (e.g. "unix:path=/run/user/1000/bus,guid=...").
pub fn parseUnixAddress(raw: []const u8) []const u8 {
    var s = raw;
    if (std.mem.startsWith(u8, s, "unix:path=")) {
        s = s[10..];
        if (std.mem.indexOfScalar(u8, s, ',')) |comma_idx| {
            return s[0..comma_idx];
        }
        return s;
    } else if (std.mem.startsWith(u8, s, "unix:abstract=")) {
        s = s[14..];
        if (std.mem.indexOfScalar(u8, s, ',')) |comma_idx| {
            return s[0..comma_idx];
        }
        return s;
    }
    return raw;
}

pub const Socket = struct {
    fd: std.posix.fd_t,

    pub const default_system_socket_path = "/var/run/dbus/system_bus_socket";

    /// Resolves the path to the D-Bus system bus (DBUS_SYSTEM_BUS_ADDRESS or default).
    pub fn getSystemBusPath(buf: []u8) []const u8 {
        if (getEnvVar("DBUS_SYSTEM_BUS_ADDRESS", buf)) |addr| {
            return parseUnixAddress(addr);
        }
        return default_system_socket_path;
    }

    /// Resolves the path to the D-Bus session bus (DBUS_SESSION_BUS_ADDRESS or /run/user/<uid>/bus).
    pub fn getSessionBusPath(buf: []u8) ![]const u8 {
        if (getEnvVar("DBUS_SESSION_BUS_ADDRESS", buf)) |addr| {
            return parseUnixAddress(addr);
        }
        if (builtin.os.tag == .linux) {
            const uid = std.posix.system.getuid();
            return std.fmt.bufPrint(buf, "/run/user/{d}/bus", .{uid}) catch error.BufferTooSmall;
        }
        return error.NotSupported;
    }

    /// Establishes connection to the D-Bus Unix domain socket.
    /// Supports standard file paths as well as D-Bus address strings (unix:path=...).
    pub fn connect(raw_path: []const u8) !Socket {
        if (builtin.os.tag != .linux) {
            return error.NotSupported;
        }

        const is_abstract = std.mem.startsWith(u8, raw_path, "unix:abstract=");
        const path = parseUnixAddress(raw_path);

        var addr = std.posix.sockaddr.un{
            .family = std.posix.AF.UNIX,
            .path = undefined,
        };
        @memset(&addr.path, 0);

        var addr_len: std.posix.socklen_t = @sizeOf(std.posix.sockaddr.un);
        if (is_abstract) {
            addr.path[0] = 0; // Abstract Unix domain socket starts with NUL byte
            const copy_len = @min(addr.path.len - 2, path.len);
            @memcpy(addr.path[1 .. 1 + copy_len], path[0..copy_len]);
            addr_len = @intCast(@offsetOf(std.posix.sockaddr.un, "path") + 1 + copy_len);
        } else {
            const copy_len = @min(addr.path.len - 1, path.len);
            @memcpy(addr.path[0..copy_len], path[0..copy_len]);
            addr.path[copy_len] = 0;
        }

        const rc = std.posix.system.socket(std.posix.AF.UNIX, std.posix.SOCK.STREAM | std.posix.SOCK.CLOEXEC, 0);
        const err = std.posix.errno(rc);
        if (err != .SUCCESS) {
            return error.IOError;
        }
        const fd: std.posix.fd_t = @intCast(rc);
        errdefer _ = std.posix.system.close(fd);

        const conn_rc = std.posix.system.connect(fd, @ptrCast(&addr), addr_len);
        const conn_err = std.posix.errno(conn_rc);
        if (conn_err != .SUCCESS) {
            return switch (conn_err) {
                .NOENT => error.FileNotFound,
                .ACCES => error.AccessDenied,
                else => error.IOError,
            };
        }

        return Socket{ .fd = fd };
    }

    pub fn close(self: *Socket) void {
        if (self.fd >= 0) {
            _ = std.posix.system.close(self.fd);
            self.fd = -1;
        }
    }

    /// Sends all bytes blocking over the socket.
    pub fn writeAll(self: Socket, bytes: []const u8) !void {
        var written: usize = 0;
        while (written < bytes.len) {
            const rc = std.posix.system.write(self.fd, bytes[written..].ptr, bytes.len - written);
            const err = std.posix.errno(rc);
            if (err != .SUCCESS) {
                return switch (err) {
                    .PIPE => error.BrokenPipe,
                    .CONNRESET => error.ConnectionReset,
                    else => error.IOError,
                };
            }
            if (rc == 0) return error.BrokenPipe;
            written += @intCast(rc);
        }
    }

    /// Sends bytes including attached file descriptors via SCM_RIGHTS ancillary message (CMSG).
    pub fn sendWithFds(self: Socket, bytes: []const u8, fds: []const std.posix.fd_t) !usize {
        var s_iov = [1]std.posix.iovec_const{.{
            .base = bytes.ptr,
            .len = bytes.len,
        }};

        var cmsg_buf: [256]u8 align(@alignOf(std.os.linux.cmsghdr)) = undefined;
        @memset(&cmsg_buf, 0);

        const data_offset = std.mem.alignForward(usize, @sizeOf(std.os.linux.cmsghdr), @alignOf(std.posix.fd_t));
        const fds_bytes = fds.len * @sizeOf(std.posix.fd_t);
        const total_cmsg_len = data_offset + fds_bytes;
        if (total_cmsg_len > cmsg_buf.len) return error.TooManyDescriptors;

        const cmsg: *std.os.linux.cmsghdr = @ptrCast(&cmsg_buf);
        cmsg.level = std.posix.SOL.SOCKET;
        cmsg.type = std.posix.SCM.RIGHTS;
        cmsg.len = total_cmsg_len;

        for (fds, 0..) |fd, i| {
            const offset = data_offset + i * @sizeOf(std.posix.fd_t);
            @memcpy(cmsg_buf[offset .. offset + @sizeOf(std.posix.fd_t)], std.mem.asBytes(&fd));
        }

        var msg: std.posix.msghdr_const = .{
            .name = null,
            .namelen = 0,
            .iov = &s_iov,
            .iovlen = 1,
            .control = &cmsg_buf,
            .controllen = total_cmsg_len,
            .flags = 0,
        };

        const rc = std.posix.system.sendmsg(self.fd, &msg, 0);
        const err = std.posix.errno(rc);
        if (err != .SUCCESS) {
            return switch (err) {
                .PIPE => error.BrokenPipe,
                .CONNRESET => error.ConnectionReset,
                else => error.IOError,
            };
        }
        if (rc == 0) return error.BrokenPipe;
        return @intCast(rc);
    }

    /// Writes all bytes, transmitting file descriptors with the initial chunk.
    pub fn writeAllWithFds(self: Socket, bytes: []const u8, fds: []const std.posix.fd_t) !void {
        if (fds.len == 0) {
            return self.writeAll(bytes);
        }
        const sent = try self.sendWithFds(bytes, fds);
        if (sent < bytes.len) {
            try self.writeAll(bytes[sent..]);
        }
    }

    /// Reads available bytes into buffer (blocks until at least 1 byte arrives).
    pub fn read(self: Socket, buf: []u8) !usize {
        return std.posix.read(self.fd, buf);
    }

    /// Reads exactly buf.len bytes from the socket.
    pub fn readExact(self: Socket, buf: []u8) !void {
        var total_read: usize = 0;
        while (total_read < buf.len) {
            const n = try std.posix.read(self.fd, buf[total_read..]);
            if (n == 0) return error.EndOfStream;
            total_read += n;
        }
    }

    /// Reads bytes and captures incoming file descriptors via SCM_RIGHTS.
    pub fn recvWithFds(self: Socket, buf: []u8, fds_out: []std.posix.fd_t) !struct { bytes_read: usize, fds_read: usize } {
        var r_iov = [1]std.posix.iovec{.{
            .base = buf.ptr,
            .len = buf.len,
        }};
        var r_cmsg_buf: [256]u8 align(@alignOf(std.os.linux.cmsghdr)) = undefined;
        @memset(&r_cmsg_buf, 0);

        var r_msg: std.posix.msghdr = .{
            .name = null,
            .namelen = 0,
            .iov = &r_iov,
            .iovlen = 1,
            .control = &r_cmsg_buf,
            .controllen = r_cmsg_buf.len,
            .flags = 0,
        };

        const rc = std.posix.system.recvmsg(self.fd, &r_msg, 0);
        const err = std.posix.errno(rc);
        if (err != .SUCCESS) {
            return switch (err) {
                .CONNRESET => error.ConnectionReset,
                .AGAIN => error.WouldBlock,
                else => error.IOError,
            };
        }
        if (rc == 0) return error.EndOfStream;
        const bytes_read: usize = @intCast(rc);

        var fds_read: usize = 0;
        const data_offset = std.mem.alignForward(usize, @sizeOf(std.os.linux.cmsghdr), @alignOf(std.posix.fd_t));
        if (r_msg.controllen >= data_offset + @sizeOf(std.posix.fd_t)) {
            const cmsg: *std.os.linux.cmsghdr = @ptrCast(&r_cmsg_buf);
            if (cmsg.level == std.posix.SOL.SOCKET and cmsg.type == std.posix.SCM.RIGHTS) {
                const payload_len = if (cmsg.len > data_offset) cmsg.len - data_offset else 0;
                const count = @min(payload_len / @sizeOf(std.posix.fd_t), fds_out.len);
                for (0..count) |i| {
                    const offset = data_offset + i * @sizeOf(std.posix.fd_t);
                    const fd_val = std.mem.bytesAsValue(std.posix.fd_t, r_cmsg_buf[offset .. offset + @sizeOf(std.posix.fd_t)]);
                    fds_out[i] = fd_val.*;
                }
                fds_read = count;
            }
        }

        return .{ .bytes_read = bytes_read, .fds_read = fds_read };
    }

    /// Waits for incoming data with timeout in milliseconds.
    /// Uses native Linux kernel poll (zero CPU overhead).
    pub fn pollRead(self: Socket, timeout_ms: i32) !bool {
        var pfd = [1]std.posix.pollfd{.{
            .fd = self.fd,
            .events = std.posix.POLL.IN,
            .revents = 0,
        }};

        const ret = try std.posix.poll(&pfd, timeout_ms);
        if (ret > 0) {
            if ((pfd[0].revents & std.posix.POLL.IN) != 0) {
                return true;
            }
            if ((pfd[0].revents & (std.posix.POLL.ERR | std.posix.POLL.HUP | std.posix.POLL.NVAL)) != 0) {
                return error.ConnectionReset;
            }
            return false;
        }
        return false;
    }
};

test "parseUnixAddress formats" {
    try std.testing.expectEqualStrings(
        "/var/run/dbus/system_bus_socket",
        parseUnixAddress("unix:path=/var/run/dbus/system_bus_socket,guid=1234"),
    );
    try std.testing.expectEqualStrings(
        "/tmp/custom_bus",
        parseUnixAddress("unix:path=/tmp/custom_bus"),
    );
    try std.testing.expectEqualStrings(
        "/var/run/dbus/system_bus_socket",
        parseUnixAddress("/var/run/dbus/system_bus_socket"),
    );
}
