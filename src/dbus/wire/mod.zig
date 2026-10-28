//! Pure-Zig D-Bus Wire Protocol Suite
//! 100% free of libdbus-1, libc, and external C headers.

pub const types = @import("types.zig");
pub const Type = types.Type;
pub const MessageType = types.MessageType;
pub const HeaderField = types.HeaderField;

pub const socket = @import("socket.zig");
pub const Socket = socket.Socket;

pub const auth = @import("auth.zig");
pub const header = @import("header.zig");
pub const FixedHeader = header.FixedHeader;
pub const HeaderFields = header.HeaderFields;

pub const reader = @import("reader.zig");
pub const MessageIter = reader.MessageIter;

pub const writer = @import("writer.zig");
pub const MessageBuilder = writer.MessageBuilder;

pub const buffer = @import("buffer.zig");
pub const ByteBuffer = buffer.ByteBuffer;
pub const List = buffer.List;

pub const message = @import("message.zig");
pub const Message = message.Message;

pub const connection = @import("connection.zig");
pub const Connection = connection.Connection;
pub const DBusError = connection.DBusError;
pub const RequestNameFlags = connection.RequestNameFlags;
pub const RequestNameReply = connection.RequestNameReply;
pub const ReleaseNameReply = connection.ReleaseNameReply;

pub const NonLinuxConnection = struct {
    pub fn initSystem() error{NotSupported}!@This() {
        return error.NotSupported;
    }
    pub fn deinit(self: *@This()) void {
        _ = self;
    }
    pub fn addMatch(self: *@This(), rule: [:0]const u8) error{NotSupported}!void {
        _ = self;
        _ = rule;
        return error.NotSupported;
    }
    pub fn pollSocket(self: *@This(), timeout_ms: c_int) usize {
        _ = self;
        _ = timeout_ms;
        return 0;
    }
    pub fn popMessage(self: *@This()) ?Message {
        _ = self;
        return null;
    }
    pub fn popMatching(
        self: *@This(),
        context: anytype,
        comptime predicate: anytype,
    ) ?Message {
        _ = self;
        _ = context;
        _ = predicate;
        return null;
    }
    pub fn requeueMessage(self: *@This(), msg: Message) error{NotSupported}!void {
        _ = self;
        _ = msg;
        return error.NotSupported;
    }
    pub fn callMethod(
        self: *@This(),
        dest: [:0]const u8,
        path: [:0]const u8,
        iface: [:0]const u8,
        method: [:0]const u8,
        timeout_ms: u32,
    ) error{NotSupported}!Message {
        _ = self;
        _ = dest;
        _ = path;
        _ = iface;
        _ = method;
        _ = timeout_ms;
        return error.NotSupported;
    }
    pub fn sendMessage(self: *@This(), msg: *Message, timeout_ms: u32) error{NotSupported}!Message {
        _ = self;
        _ = msg;
        _ = timeout_ms;
        return error.NotSupported;
    }
};

test {
    _ = types;
    _ = socket;
    _ = auth;
    _ = header;
    _ = buffer;
    _ = reader;
    _ = writer;
    _ = message;
    _ = connection;
}
