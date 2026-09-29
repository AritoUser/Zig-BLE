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
