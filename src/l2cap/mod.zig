//! # L2CAP (Logical Link Control and Adaptation Protocol)
//!
//! Provides direct L2CAP Connection-Oriented Channel (CoC) streaming
//! over Linux `AF_BLUETOOTH`.

pub const socket = @import("socket.zig");
pub const L2capSocket = socket.L2capSocket;
pub const sockaddr_l2 = socket.sockaddr_l2;
pub const SocketType = socket.SocketType;
pub const L2capError = socket.L2capError;

test {
    const std = @import("std");
    std.testing.refAllDecls(@This());
    _ = socket;
}
