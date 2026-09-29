//! D-Bus Message Model (Pure Zig)
//! Represents incoming and outgoing D-Bus messages with zero-copy access.
//! Full support for file descriptors (UNIX FDs), signatures, and header fields.

const std = @import("std");
const builtin = @import("builtin");
const types = @import("types.zig");
const Type = types.Type;
const MessageType = types.MessageType;
const HeaderField = types.HeaderField;
const header = @import("header.zig");
const FixedHeader = header.FixedHeader;
const HeaderFields = header.HeaderFields;
const reader = @import("reader.zig");
const MessageIter = reader.MessageIter;
const writer = @import("writer.zig");
const MessageBuilder = writer.MessageBuilder;
const ByteBuffer = @import("buffer.zig").ByteBuffer;

pub const invalid_fd: std.posix.fd_t = if (builtin.os.tag == .windows) std.os.windows.INVALID_HANDLE_VALUE else -1;

pub const Message = struct {
    allocator: std.mem.Allocator,
    fixed_header: FixedHeader,
    header_fields: HeaderFields,
    /// Full raw buffer of the message (header + fields + padding + body)
    wire_bytes: ByteBuffer,
    /// Buffer for dynamically constructed body data (only for outgoing messages)
    body_builder_buf: ?ByteBuffer = null,
    body_sig_buf: ?ByteBuffer = null,

    // Pre-configured fields for outgoing messages prior to finalization
    destination: ?[:0]const u8 = null,
    path: ?[:0]const u8 = null,
    interface: ?[:0]const u8 = null,
    member: ?[:0]const u8 = null,
    error_name: ?[:0]const u8 = null,
    reply_serial: ?u32 = null,

    /// Attached Unix file descriptors (SCM_RIGHTS)
    fds: [8]std.posix.fd_t = [_]std.posix.fd_t{invalid_fd} ** 8,
    fd_count: u8 = 0,

    pub fn deinit(self: Message) void {
        self.wire_bytes.deinit();
        if (self.body_builder_buf) |b| b.deinit();
        if (self.body_sig_buf) |s| s.deinit();
        for (self.fds[0..self.fd_count]) |fd| {
            if (isFdValid(fd)) {
                if (builtin.os.tag != .windows) {
                    _ = std.posix.system.close(fd);
                } else {
                    _ = std.os.windows.CloseHandle(fd);
                }
            }
        }
    }

    /// Appends a file descriptor to the message and returns its index (for type 'h').
    pub fn appendFd(self: *Message, fd: std.posix.fd_t) !u32 {
        if (self.fd_count >= self.fds.len) return error.TooManyDescriptors;
        const idx = self.fd_count;
        self.fds[idx] = fd;
        self.fd_count += 1;
        return idx;
    }

    pub fn isFdValid(fd: std.posix.fd_t) bool {
        if (builtin.os.tag == .windows) {
            return fd != std.os.windows.INVALID_HANDLE_VALUE;
        } else {
            return fd >= 0;
        }
    }

    /// Returns the file descriptor at index without releasing ownership.
    pub fn getUnixFd(self: *const Message, index: u32) ?std.posix.fd_t {
        if (index >= self.fd_count) return null;
        const fd = self.fds[index];
        if (!isFdValid(fd)) return null;
        return fd;
    }

    /// Extracts the file descriptor and transfers ownership to caller (deinit will not close it).
    pub fn extractFd(self: *Message, index: u32) ?std.posix.fd_t {
        if (index >= self.fd_count) return null;
        const fd = self.fds[index];
        if (!isFdValid(fd)) return null;
        self.fds[index] = invalid_fd;
        return fd;
    }

    /// Creates a read iterator over the body of this message.
    pub fn iterator(self: *const Message) MessageIter {
        const body_offset = header.calcBodyOffset(self.fixed_header.fields_len);
        const sig = self.header_fields.signature orelse "";
        const end_offset = body_offset + self.fixed_header.body_len;

        return MessageIter.initEndian(self.wire_bytes.getSlice(), body_offset, end_offset, sig, self.fixed_header.getEndian());
    }

    /// Initializes a builder for appending arguments to this message.
    pub fn builder(self: *Message) MessageBuilder {
        if (self.body_builder_buf == null) {
            self.body_builder_buf = ByteBuffer.init(self.allocator);
            self.body_sig_buf = ByteBuffer.init(self.allocator);
        }
        return MessageBuilder.init(&self.body_builder_buf.?, &self.body_sig_buf.?);
    }

    pub fn getMessageType(self: *const Message) c_int {
        return @intFromEnum(self.fixed_header.msg_type);
    }

    pub fn getInterface(self: *const Message) ?[:0]const u8 {
        const iface = self.header_fields.interface orelse self.interface orelse return null;
        return @ptrCast(iface);
    }

    pub fn getMember(self: *const Message) ?[:0]const u8 {
        const mem = self.header_fields.member orelse self.member orelse return null;
        return @ptrCast(mem);
    }

    pub fn getPath(self: *const Message) ?[:0]const u8 {
        const p = self.header_fields.path orelse self.path orelse return null;
        return @ptrCast(p);
    }
    pub const getObjectPath = getPath;

    pub fn getSender(self: *const Message) ?[:0]const u8 {
        const snd = self.header_fields.sender orelse return null;
        return @ptrCast(snd);
    }

    pub fn getReplySerial(self: *const Message) u32 {
        return self.header_fields.reply_serial orelse self.reply_serial orelse 0;
    }

    pub fn getSerial(self: *const Message) u32 {
        return self.fixed_header.serial;
    }

    pub fn getErrorName(self: *const Message) ?[:0]const u8 {
        const err = self.header_fields.error_name orelse self.error_name orelse return null;
        return @ptrCast(err);
    }

    /// Creates a new method call message.
    pub fn createMethodCall(
        allocator: std.mem.Allocator,
        dest: [:0]const u8,
        path_str: [:0]const u8,
        iface: [:0]const u8,
        method: [:0]const u8,
    ) !Message {
        return Message{
            .allocator = allocator,
            .fixed_header = FixedHeader{
                .msg_type = .method_call,
                .body_len = 0,
                .serial = 0,
                .fields_len = 0,
            },
            .header_fields = HeaderFields{},
            .wire_bytes = ByteBuffer.init(allocator),
            .destination = dest,
            .path = path_str,
            .interface = iface,
            .member = method,
        };
    }

    /// Creates a signal message.
    pub fn createSignal(
        allocator: std.mem.Allocator,
        path_str: [:0]const u8,
        iface: [:0]const u8,
        name: [:0]const u8,
    ) !Message {
        return Message{
            .allocator = allocator,
            .fixed_header = FixedHeader{
                .msg_type = .signal,
                .body_len = 0,
                .serial = 0,
                .fields_len = 0,
            },
            .header_fields = HeaderFields{},
            .wire_bytes = ByteBuffer.init(allocator),
            .path = path_str,
            .interface = iface,
            .member = name,
        };
    }

    /// Creates a method return message responding to a request.
    pub fn createMethodReturn(allocator: std.mem.Allocator, request: *const Message) !Message {
        return Message{
            .allocator = allocator,
            .fixed_header = FixedHeader{
                .msg_type = .method_return,
                .body_len = 0,
                .serial = 0,
                .fields_len = 0,
            },
            .header_fields = HeaderFields{},
            .wire_bytes = ByteBuffer.init(allocator),
            .destination = request.getSender(),
            .reply_serial = request.getSerial(),
        };
    }

    /// Creates an error reply message responding to a request.
    pub fn createErrorReply(
        allocator: std.mem.Allocator,
        request: *const Message,
        err_name: [:0]const u8,
        err_msg: [:0]const u8,
    ) !Message {
        var msg = Message{
            .allocator = allocator,
            .fixed_header = FixedHeader{
                .msg_type = .error_reply,
                .body_len = 0,
                .serial = 0,
                .fields_len = 0,
            },
            .header_fields = HeaderFields{},
            .wire_bytes = ByteBuffer.init(allocator),
            .destination = request.getSender(),
            .error_name = err_name,
            .reply_serial = request.getSerial(),
        };
        var b = msg.builder();
        try b.appendString(err_msg);
        return msg;
    }

    /// Finalizes the message and serializes the complete wire block with serial.
    pub fn finalize(self: *Message, serial: u32) ![]const u8 {
        self.fixed_header.serial = serial;
        self.wire_bytes.clearRetainingCapacity();

        // 1. Temporary buffer for header fields a(yv) on the stack (zero heap allocations)
        // 2048 bytes comfortably accommodates long object paths, interfaces, and signatures.
        var stack_fields: [2048]u8 = undefined;
        var fba = std.heap.FixedBufferAllocator.init(&stack_fields);
        var fields_buf = ByteBuffer.init(fba.allocator());
        defer fields_buf.deinit();

        // Path (Field 1, 'o')
        if (self.path) |p| {
            try appendHeaderField(&fields_buf, HeaderField.path, "o", p);
        }
        // Interface (Field 2, 's')
        if (self.interface) |iface| {
            try appendHeaderField(&fields_buf, HeaderField.interface, "s", iface);
        }
        // Member (Field 3, 's')
        if (self.member) |mem| {
            try appendHeaderField(&fields_buf, HeaderField.member, "s", mem);
        }
        // ErrorName (Field 4, 's')
        if (self.error_name) |err_n| {
            try appendHeaderField(&fields_buf, HeaderField.error_name, "s", err_n);
        }
        // ReplySerial (Field 5, 'u')
        if (self.reply_serial) |r_ser| {
            try appendHeaderFieldUint32(&fields_buf, HeaderField.reply_serial, r_ser);
        }
        // Destination (Field 6, 's')
        if (self.destination) |dest| {
            try appendHeaderField(&fields_buf, HeaderField.destination, "s", dest);
        }
        // Signature (Field 8, 'g')
        if (self.body_sig_buf) |*sig_b| {
            if (sig_b.len > 0) {
                try appendHeaderFieldSignature(&fields_buf, HeaderField.signature, sig_b.getSlice());
            }
        }
        // Unix FDs (Field 9, 'u')
        if (self.fd_count > 0) {
            try appendHeaderFieldUint32(&fields_buf, HeaderField.unix_fds, self.fd_count);
        }

        const fields_len: u32 = @intCast(fields_buf.len);
        self.fixed_header.fields_len = fields_len;

        const body_len: u32 = if (self.body_builder_buf) |*b| @intCast(b.len) else 0;
        self.fixed_header.body_len = body_len;

        // 2. Encode fixed 16-byte header
        var fixed_bytes: [16]u8 = undefined;
        self.fixed_header.encode(&fixed_bytes);
        try self.wire_bytes.appendSlice(&fixed_bytes);

        // 3. Append header fields
        try self.wire_bytes.appendSlice(fields_buf.getSlice());

        // 4. Insert computed padding up to next 8-byte offset for the body
        const padding = header.calcHeaderPadding(fields_len);
        if (padding > 0) {
            try self.wire_bytes.appendNTimes(0, padding);
        }

        // 5. Append body bytes
        if (self.body_builder_buf) |*b| {
            try self.wire_bytes.appendSlice(b.getSlice());
        }

        return self.wire_bytes.getSlice();
    }

    fn appendHeaderField(buf: *ByteBuffer, code: u8, sig: [:0]const u8, str_val: []const u8) !void {
        const pad = types.paddingRequired(16 + buf.len, 8);
        if (pad > 0) try buf.appendNTimes(0, pad);

        try buf.append(code); // y
        try buf.append(@intCast(sig.len)); // Signature length
        try buf.appendSlice(sig);
        try buf.append(0); // null terminator

        const str_pad = types.paddingRequired(16 + buf.len, 4);
        if (str_pad > 0) try buf.appendNTimes(0, str_pad);

        const len: u32 = @intCast(str_val.len);
        var len_bytes: [4]u8 = undefined;
        std.mem.writeInt(u32, &len_bytes, len, .little);
        try buf.appendSlice(&len_bytes);
        try buf.appendSlice(str_val);
        try buf.append(0);
    }

    fn appendHeaderFieldUint32(buf: *ByteBuffer, code: u8, val: u32) !void {
        const pad = types.paddingRequired(16 + buf.len, 8);
        if (pad > 0) try buf.appendNTimes(0, pad);

        try buf.append(code);
        try buf.append(1); // Signature 'u' len
        try buf.append('u');
        try buf.append(0);

        const val_pad = types.paddingRequired(16 + buf.len, 4);
        if (val_pad > 0) try buf.appendNTimes(0, val_pad);

        var val_bytes: [4]u8 = undefined;
        std.mem.writeInt(u32, &val_bytes, val, .little);
        try buf.appendSlice(&val_bytes);
    }

    fn appendHeaderFieldSignature(buf: *ByteBuffer, code: u8, sig_val: []const u8) !void {
        const pad = types.paddingRequired(16 + buf.len, 8);
        if (pad > 0) try buf.appendNTimes(0, pad);

        try buf.append(code);
        try buf.append(1); // Signature 'g' len
        try buf.append('g');
        try buf.append(0);

        try buf.append(@intCast(sig_val.len));
        try buf.appendSlice(sig_val);
        try buf.append(0);
    }
};

test "Message createMethodCall and finalize with 8-byte body padding" {
    var msg = try Message.createMethodCall(
        std.testing.allocator,
        "org.freedesktop.DBus",
        "/org/freedesktop/DBus",
        "org.freedesktop.DBus",
        "Hello",
    );
    defer msg.deinit();

    const wire = try msg.finalize(1);
    try std.testing.expect(wire.len >= 16);

    const decoded_hdr = try FixedHeader.decode(wire[0..16]);
    try std.testing.expectEqual(MessageType.method_call, decoded_hdr.msg_type);
    try std.testing.expectEqual(@as(u32, 1), decoded_hdr.serial);
    try std.testing.expectEqual(@as(u32, 0), decoded_hdr.body_len);

    const body_offset = header.calcBodyOffset(decoded_hdr.fields_len);
    try std.testing.expectEqual(@as(usize, 0), body_offset % 8);
}

test "Message appendFd and extractFd" {
    var msg = try Message.createMethodCall(
        std.testing.allocator,
        "org.bluez",
        "/org/bluez/test",
        "org.bluez.Test1",
        "SendFd",
    );
    defer msg.deinit();

    const fake_fd: std.posix.fd_t = if (builtin.os.tag == .windows) @ptrFromInt(42) else 42;
    const idx0 = try msg.appendFd(fake_fd);
    try std.testing.expectEqual(@as(u32, 0), idx0);
    try std.testing.expectEqual(@as(?std.posix.fd_t, fake_fd), msg.getUnixFd(0));

    const extracted = msg.extractFd(0);
    try std.testing.expectEqual(@as(?std.posix.fd_t, fake_fd), extracted);
    try std.testing.expectEqual(@as(?std.posix.fd_t, null), msg.getUnixFd(0));
}
