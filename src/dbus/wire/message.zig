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
    fds: [8]std.posix.fd_t = @splat(invalid_fd),
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

        // 1. Format header fields directly into L1 stack buffer (zero allocations, zero reallocations)
        var stack_fields: [2048]u8 = undefined;
        var fields_len: usize = 0;

        if (self.path) |p| appendFieldRaw(&stack_fields, &fields_len, HeaderField.path, "o", p);
        if (self.interface) |iface| appendFieldRaw(&stack_fields, &fields_len, HeaderField.interface, "s", iface);
        if (self.member) |mem| appendFieldRaw(&stack_fields, &fields_len, HeaderField.member, "s", mem);
        if (self.error_name) |err_n| appendFieldRaw(&stack_fields, &fields_len, HeaderField.error_name, "s", err_n);
        if (self.reply_serial) |r_ser| appendFieldUint32Raw(&stack_fields, &fields_len, HeaderField.reply_serial, r_ser);
        if (self.destination) |dest| appendFieldRaw(&stack_fields, &fields_len, HeaderField.destination, "s", dest);
        if (self.body_sig_buf) |*sig_b| {
            if (sig_b.len > 0) appendFieldSignatureRaw(&stack_fields, &fields_len, HeaderField.signature, sig_b.getSlice());
        }
        if (self.fd_count > 0) appendFieldUint32Raw(&stack_fields, &fields_len, HeaderField.unix_fds, self.fd_count);

        const fields_len_u32: u32 = @intCast(fields_len);
        self.fixed_header.fields_len = fields_len_u32;

        const body_len: u32 = if (self.body_builder_buf) |*b| @intCast(b.len) else 0;
        self.fixed_header.body_len = body_len;

        const padding = header.calcHeaderPadding(fields_len_u32);
        const total_size = 16 + fields_len + padding + body_len;

        // 2. Pre-allocate exact wire buffer capacity in one shot
        try self.wire_bytes.ensureTotalCapacity(total_size);
        const out_dest = self.wire_bytes.data;

        // 3. Fast contiguous layout
        self.fixed_header.encode(out_dest[0..16]);
        @memcpy(out_dest[16 .. 16 + fields_len], stack_fields[0..fields_len]);

        if (padding > 0) {
            @memset(out_dest[16 + fields_len .. 16 + fields_len + padding], 0);
        }

        if (self.body_builder_buf) |*b| {
            const body_start = 16 + fields_len + padding;
            @memcpy(out_dest[body_start .. body_start + body_len], b.getSlice());
        }

        self.wire_bytes.len = total_size;
        return self.wire_bytes.getSlice();
    }

    inline fn appendFieldRaw(dest: []u8, cursor: *usize, code: u8, sig: [:0]const u8, str_val: []const u8) void {
        const c = cursor.*;
        const pad = types.paddingRequired(16 + c, 8);
        @memset(dest[c .. c + pad], 0);
        var cur = c + pad;

        dest[cur] = code;
        dest[cur + 1] = @intCast(sig.len);
        cur += 2;

        @memcpy(dest[cur .. cur + sig.len], sig);
        cur += sig.len;
        dest[cur] = 0;
        cur += 1;

        const str_pad = types.paddingRequired(16 + cur, 4);
        @memset(dest[cur .. cur + str_pad], 0);
        cur += str_pad;

        std.mem.writeInt(u32, dest[cur .. cur + 4][0..4], @intCast(str_val.len), .little);
        cur += 4;

        @memcpy(dest[cur .. cur + str_val.len], str_val);
        cur += str_val.len;
        dest[cur] = 0;
        cur += 1;

        cursor.* = cur;
    }

    inline fn appendFieldUint32Raw(dest: []u8, cursor: *usize, code: u8, val: u32) void {
        const c = cursor.*;
        const pad = types.paddingRequired(16 + c, 8);
        @memset(dest[c .. c + pad], 0);
        var cur = c + pad;

        dest[cur] = code;
        dest[cur + 1] = 1;
        dest[cur + 2] = 'u';
        dest[cur + 3] = 0;
        cur += 4;

        const val_pad = types.paddingRequired(16 + cur, 4);
        @memset(dest[cur .. cur + val_pad], 0);
        cur += val_pad;

        std.mem.writeInt(u32, dest[cur .. cur + 4][0..4], val, .little);
        cur += 4;

        cursor.* = cur;
    }

    inline fn appendFieldSignatureRaw(dest: []u8, cursor: *usize, code: u8, sig_val: []const u8) void {
        const c = cursor.*;
        const pad = types.paddingRequired(16 + c, 8);
        @memset(dest[c .. c + pad], 0);
        var cur = c + pad;

        dest[cur] = code;
        dest[cur + 1] = 1;
        dest[cur + 2] = 'g';
        dest[cur + 3] = 0;
        cur += 4;

        dest[cur] = @intCast(sig_val.len);
        cur += 1;

        @memcpy(dest[cur .. cur + sig_val.len], sig_val);
        cur += sig_val.len;
        dest[cur] = 0;
        cur += 1;

        cursor.* = cur;
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
