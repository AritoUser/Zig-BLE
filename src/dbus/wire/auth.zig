//! D-Bus SASL EXTERNAL Authentication
//! Implements spec-compliant ASCII hex handshake over UNIX domain sockets.

const std = @import("std");
const builtin = @import("builtin");
const Socket = @import("socket.zig").Socket;

pub const AuthError = error{
    AuthFailed,
    InvalidResponse,
    EndOfStream,
    BrokenPipe,
    ConnectionReset,
    Unexpected,
    NotSupported,
};

/// Encodes an integer UID into the ASCII hex format required by D-Bus.
/// Example: UID 0 -> "30", UID 1000 -> "31303030".
pub fn formatUidHex(uid: u32, dest: []u8) ![]const u8 {
    var dec_buf: [16]u8 = undefined;
    const dec_str = std.fmt.bufPrint(&dec_buf, "{d}", .{uid}) catch return error.Unexpected;

    if (dest.len < dec_str.len * 2) return error.Unexpected;

    const hex = "0123456789abcdef";
    for (dec_str, 0..) |c, i| {
        dest[i * 2] = hex[(c >> 4) & 0x0F];
        dest[i * 2 + 1] = hex[c & 0x0F];
    }
    return dest[0 .. dec_str.len * 2];
}

pub const AuthResult = struct {
    guid: [64]u8 = undefined,
    guid_len: u8 = 0,
    supports_unix_fd: bool = false,
};

/// Reads a line terminated by "\r\n" from the socket.
fn readLine(socket: Socket, dest: []u8) ![]const u8 {
    var line_len: usize = 0;
    while (line_len < dest.len) {
        var byte_buf: [1]u8 = undefined;
        try socket.readExact(&byte_buf);
        dest[line_len] = byte_buf[0];
        line_len += 1;
        if (line_len >= 2 and dest[line_len - 2] == '\r' and dest[line_len - 1] == '\n') {
            return dest[0 .. line_len - 2];
        }
    }
    return AuthError.InvalidResponse;
}

/// Performs SASL EXTERNAL authentication and negotiates UNIX FD passing support.
pub fn authenticate(socket: Socket) !AuthResult {
    if (builtin.os.tag != .linux) {
        return AuthError.NotSupported;
    }

    const uid = std.posix.system.getuid();

    // 1. Format UID into hex
    var hex_buf: [32]u8 = undefined;
    const hex_uid = try formatUidHex(uid, &hex_buf);

    // 2. Compose handshake command: "\0AUTH EXTERNAL <hex_uid>\r\n"
    var send_buf: [64]u8 = undefined;
    const msg = std.fmt.bufPrint(&send_buf, "\x00AUTH EXTERNAL {s}\r\n", .{hex_uid}) catch return AuthError.Unexpected;
    try socket.writeAll(msg);

    // 3. Read reply line from server (e.g. "OK <guid>\r\n")
    var line_buf: [128]u8 = undefined;
    const reply = try readLine(socket, &line_buf);

    if (!std.mem.startsWith(u8, reply, "OK ")) {
        return AuthError.AuthFailed;
    }

    var result = AuthResult{};
    const guid_part = reply[3..];
    const copy_len = @min(result.guid.len, guid_part.len);
    @memcpy(result.guid[0..copy_len], guid_part[0..copy_len]);
    result.guid_len = @intCast(copy_len);

    // 4. Negotiate UNIX FD passing ("NEGOTIATE_UNIX_FD\r\n")
    try socket.writeAll("NEGOTIATE_UNIX_FD\r\n");
    const neg_reply = try readLine(socket, &line_buf);
    if (std.mem.startsWith(u8, neg_reply, "AGREE_UNIX_FD")) {
        result.supports_unix_fd = true;
    }

    // 5. Send "BEGIN\r\n" to transition into D-Bus binary protocol
    try socket.writeAll("BEGIN\r\n");
    return result;
}

test "SASL EXTERNAL UID hex encoding" {
    var buf: [32]u8 = undefined;

    const root_hex = try formatUidHex(0, &buf);
    try std.testing.expectEqualStrings("30", root_hex);

    const user_hex = try formatUidHex(1000, &buf);
    try std.testing.expectEqualStrings("31303030", user_hex);

    const user2_hex = try formatUidHex(65534, &buf); // nobody
    try std.testing.expectEqualStrings("3635353334", user2_hex);
}
