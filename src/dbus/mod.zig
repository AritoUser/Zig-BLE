//! Zig D-Bus Abstraction Layer for Linux BlueZ (100% Pure Zig Wire Protocol).
const std = @import("std");

pub const wire = @import("wire/mod.zig");

pub const DBusError = wire.DBusError;
pub const Connection = wire.Connection;
pub const Message = wire.Message;
pub const MessageIter = wire.MessageIter;
pub const MessageBuilder = wire.MessageBuilder;

test {
    _ = wire;
}

