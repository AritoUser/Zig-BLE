//! Native Pure-Zig D-Bus Connection Engine
//! Manages UNIX socket, serial numbers, synchronous calls, and asynchronous signal dispatching.
//! 100% Pure Zig via std.posix (0 C-Dependencies).

const std = @import("std");
const builtin = @import("builtin");
const types = @import("types.zig");
const MessageType = types.MessageType;
const header = @import("header.zig");
const FixedHeader = header.FixedHeader;
const HeaderFields = header.HeaderFields;
const socket_mod = @import("socket.zig");
const Socket = socket_mod.Socket;
const auth = @import("auth.zig");
const buffer_mod = @import("buffer.zig");
const ByteBuffer = buffer_mod.ByteBuffer;
const List = buffer_mod.List;
const message_mod = @import("message.zig");
pub const Message = message_mod.Message;
pub const MessageIter = @import("reader.zig").MessageIter;
pub const MessageBuilder = @import("writer.zig").MessageBuilder;

pub const DBusError = error{
    Failed,
    NoMemory,
    ServiceUnknown,
    NameHasNoOwner,
    NoReply,
    IOError,
    BadAddress,
    NotSupported,
    LimitsExceeded,
    AccessDenied,
    AuthFailed,
    NoServer,
    Timeout,
    UnknownMethod,
    UnknownInterface,
    UnknownObject,
    UnknownProperty,
    PropertyReadOnly,
    InvalidArgs,
    ConnectionReset,
    EndOfStream,
    BrokenPipe,
    Unexpected,
};

fn getMonotonicMs() i64 {
    if (builtin.os.tag == .linux) {
        var ts: std.os.linux.timespec = undefined;
        _ = std.os.linux.clock_gettime(std.os.linux.CLOCK.MONOTONIC, &ts);
        return @as(i64, ts.sec) * 1000 + @as(i64, @divTrunc(ts.nsec, 1_000_000));
    } else {
        return 0;
    }
}

/// D-Bus RequestName flags conforming to D-Bus specification
pub const RequestNameFlags = struct {
    pub const allow_replacement: u32 = 0x01;
    pub const replace_existing: u32 = 0x02;
    pub const do_not_queue: u32 = 0x04;
};

/// D-Bus RequestName return codes
pub const RequestNameReply = enum(u32) {
    primary_owner = 1,
    in_queue = 2,
    exists = 3,
    already_owner = 4,
};

/// D-Bus ReleaseName return codes
pub const ReleaseNameReply = enum(u32) {
    released = 1,
    non_existent = 2,
    not_owner = 3,
};

pub const Mutex = struct {
    state: std.atomic.Value(u32) = std.atomic.Value(u32).init(UNLOCKED),

    const UNLOCKED: u32 = 0;
    const LOCKED: u32 = 1;
    const CONTENDED: u32 = 2;

    pub fn lock(self: *Mutex) void {
        // Fast path: try to acquire uncontended lock
        var c = self.state.cmpxchgWeak(UNLOCKED, LOCKED, .acquire, .monotonic) orelse return;

        // Brief spin loop to avoid syscall overhead on short critical sections
        var spins: usize = 0;
        while (spins < 16) : (spins += 1) {
            if (c == UNLOCKED) {
                c = self.state.cmpxchgWeak(UNLOCKED, LOCKED, .acquire, .monotonic) orelse return;
            }
            std.atomic.spinLoopHint();
            c = self.state.load(.monotonic);
        }

        // Transition to CONTENDED state
        if (c != CONTENDED) {
            c = self.state.swap(CONTENDED, .acquire);
        }

        // Put thread to sleep in OS kernel (0% CPU on Linux) until unlocked
        while (c != UNLOCKED) {
            if (builtin.os.tag == .linux) {
                _ = std.os.linux.futex_4arg(
                    &self.state.raw,
                    .{ .cmd = .WAIT, .private = true },
                    CONTENDED,
                    null,
                );
            } else {
                std.Thread.yield() catch {};
            }
            c = self.state.swap(CONTENDED, .acquire);
        }
    }

    pub fn unlock(self: *Mutex) void {
        if (self.state.swap(UNLOCKED, .release) == CONTENDED) {
            if (builtin.os.tag == .linux) {
                _ = std.os.linux.futex_3arg(
                    &self.state.raw,
                    .{ .cmd = .WAKE, .private = true },
                    1,
                );
            }
        }
    }

    pub fn tryLock(self: *Mutex) bool {
        return self.state.cmpxchgStrong(UNLOCKED, LOCKED, .acquire, .monotonic) == null;
    }
};

pub const Connection = struct {
    allocator: std.mem.Allocator,
    socket: Socket,
    unique_name: ?[]const u8 = null,
    next_serial: u32 = 1,
    incoming_queue: List(Message),
    queue_head: usize = 0,
    supports_unix_fd: bool = false,
    write_mutex: Mutex = .{},
    read_mutex: Mutex = .{},

    /// Connects to the D-Bus system bus and authenticates.
    pub fn initSystem() DBusError!Connection {
        var path_buf: [256]u8 = undefined;
        const path = Socket.getSystemBusPath(&path_buf);
        return initWithAllocator(std.heap.page_allocator, path);
    }

    /// Connects to the D-Bus session bus (DBUS_SESSION_BUS_ADDRESS or /run/user/<uid>/bus).
    pub fn initSession() DBusError!Connection {
        var path_buf: [256]u8 = undefined;
        const path = Socket.getSessionBusPath(&path_buf) catch return DBusError.NoServer;
        return initWithAllocator(std.heap.page_allocator, path);
    }

    /// Connects to an arbitrary D-Bus address.
    pub fn initWithAddress(address: []const u8) DBusError!Connection {
        return initWithAllocator(std.heap.page_allocator, address);
    }

    pub fn initWithAllocator(allocator: std.mem.Allocator, socket_path: []const u8) DBusError!Connection {
        if (builtin.os.tag != .linux) {
            return DBusError.NotSupported;
        }

        var sock = Socket.connect(socket_path) catch |err| switch (err) {
            error.FileNotFound => return DBusError.NoServer,
            error.AccessDenied => return DBusError.AccessDenied,
            else => return DBusError.IOError,
        };
        errdefer sock.close();

        // 1. Perform SASL EXTERNAL authentication and negotiate UNIX-FD support
        const auth_res = auth.authenticate(sock) catch |err| switch (err) {
            error.AuthFailed => return DBusError.AuthFailed,
            error.AccessDenied => return DBusError.AccessDenied,
            else => return DBusError.IOError,
        };

        var conn = Connection{
            .allocator = allocator,
            .socket = sock,
            .incoming_queue = List(Message).init(allocator),
            .supports_unix_fd = auth_res.supports_unix_fd,
        };

        // 2. Initial "Hello" call to the bus daemon
        conn.unique_name = conn.performHello() catch |err| {
            conn.deinit();
            return err;
        };

        return conn;
    }

    pub fn deinit(self: *Connection) void {
        self.write_mutex.lock();
        defer self.write_mutex.unlock();
        self.read_mutex.lock();
        defer self.read_mutex.unlock();
        while (self.popMessageUnlocked()) |msg| {
            var m = msg;
            m.deinit();
        }
        self.incoming_queue.deinit();
        if (self.unique_name) |name| {
            self.allocator.free(name);
            self.unique_name = null;
        }
        self.socket.close();
    }

    /// Executes the mandatory D-Bus Hello() call.
    fn performHello(self: *Connection) DBusError![]const u8 {
        var msg = Message.createMethodCall(
            self.allocator,
            "org.freedesktop.DBus",
            "/org/freedesktop/DBus",
            "org.freedesktop.DBus",
            "Hello",
        ) catch return DBusError.NoMemory;
        defer msg.deinit();

        var reply = try self.sendMessage(&msg, 5000);
        defer reply.deinit();

        if (reply.fixed_header.msg_type == .error_reply) {
            return DBusError.Failed;
        }

        var it = reply.iterator();
        const assigned_name = it.getString() orelse return DBusError.Failed;
        return self.allocator.dupe(u8, assigned_name) catch return DBusError.NoMemory;
    }

    /// Allocates the next unique serial number for a message.
    pub fn getNextSerial(self: *Connection) u32 {
        self.write_mutex.lock();
        defer self.write_mutex.unlock();
        return self.getNextSerialUnlocked();
    }

    fn getNextSerialUnlocked(self: *Connection) u32 {
        const s = self.next_serial;
        self.next_serial +%= 1;
        if (self.next_serial == 0) self.next_serial = 1;
        return s;
    }

    /// Creates a new method call message for manual argument population.
    pub fn createMethodCall(
        dest: [:0]const u8,
        path: [:0]const u8,
        iface: [:0]const u8,
        method: [:0]const u8,
    ) DBusError!Message {
        return Message.createMethodCall(std.heap.page_allocator, dest, path, iface, method) catch return DBusError.NoMemory;
    }

    /// Creates a signal message.
    pub fn createSignal(
        path: [:0]const u8,
        iface: [:0]const u8,
        name: [:0]const u8,
    ) DBusError!Message {
        return Message.createSignal(std.heap.page_allocator, path, iface, name) catch return DBusError.NoMemory;
    }

    /// Creates a method return message responding to a request.
    pub fn createMethodReturn(request: *const Message) DBusError!Message {
        return Message.createMethodReturn(request.allocator, request) catch return DBusError.NoMemory;
    }

    /// Creates an error reply message responding to a request.
    pub fn createErrorReply(request: *const Message, err_name: [:0]const u8, err_msg: [:0]const u8) DBusError!Message {
        return Message.createErrorReply(request.allocator, request, err_name, err_msg) catch return DBusError.NoMemory;
    }

    /// Sends a message asynchronously without waiting for a reply.
    pub fn send(self: *Connection, msg: *Message) DBusError!void {
        _ = try self.sendWithSerial(msg);
    }

    /// Sends a message asynchronously and returns the allocated serial number.
    /// Supports automatic UNIX file descriptor passing (SCM_RIGHTS).
    pub fn sendWithSerial(self: *Connection, msg: *Message) DBusError!u32 {
        self.write_mutex.lock();
        defer self.write_mutex.unlock();
        return self.sendWithSerialUnlocked(msg);
    }

    fn sendWithSerialUnlocked(self: *Connection, msg: *Message) DBusError!u32 {
        const serial = self.getNextSerialUnlocked();
        const wire = msg.finalize(serial) catch return DBusError.NoMemory;

        if (msg.fd_count > 0) {
            self.socket.writeAllWithFds(wire, msg.fds[0..msg.fd_count]) catch |err| switch (err) {
                error.BrokenPipe, error.ConnectionReset => return DBusError.IOError,
                else => return DBusError.Failed,
            };
        } else {
            self.socket.writeAll(wire) catch |err| switch (err) {
                error.BrokenPipe, error.ConnectionReset => return DBusError.IOError,
                else => return DBusError.Failed,
            };
        }
        return serial;
    }

    /// Sends a message synchronously and blocks waiting for the reply (with timeout).
    /// Signals and other messages arriving in the interim are queued!
    pub fn sendMessage(self: *Connection, msg: *Message, timeout_ms: i32) DBusError!Message {
        // 1. Send request under write_mutex, release immediately so other threads can send
        const expected_serial = blk: {
            self.write_mutex.lock();
            defer self.write_mutex.unlock();
            break :blk try self.sendWithSerialUnlocked(msg);
        };

        // 2. Poll for reply under read_mutex
        self.read_mutex.lock();
        defer self.read_mutex.unlock();

        // 2a. Check if matching reply is already in the queue
        var idx = self.queue_head;
        while (idx < self.incoming_queue.len) : (idx += 1) {
            const candidate = self.incoming_queue.items[idx];
            if (candidate.fixed_header.msg_type == .method_return or candidate.fixed_header.msg_type == .error_reply) {
                if (candidate.getReplySerial() == expected_serial) {
                    std.mem.copyForwards(Message, self.incoming_queue.items[idx .. self.incoming_queue.len - 1], self.incoming_queue.items[idx + 1 .. self.incoming_queue.len]);
                    self.incoming_queue.len -= 1;
                    if (self.queue_head >= self.incoming_queue.len) {
                        self.incoming_queue.clearRetainingCapacity();
                        self.queue_head = 0;
                    }
                    if (candidate.fixed_header.msg_type == .error_reply) {
                        return mapDBusError(candidate.getErrorName());
                    }
                    return candidate;
                }
            }
        }

        // 2b. Poll socket until reply arrives or timeout expires
        const deadline = getMonotonicMs() + @as(i64, timeout_ms);

        while (true) {
            const now = getMonotonicMs();
            if (now >= deadline) {
                return DBusError.Timeout;
            }
            const remaining: i32 = @intCast(@min(@as(i64, std.math.maxInt(i32)), deadline - now));

            const has_data = self.socket.pollRead(remaining) catch return DBusError.IOError;
            if (!has_data) {
                return DBusError.Timeout;
            }

            var incoming = self.readNextMessageFromSocket() catch |err| switch (err) {
                error.EndOfStream => return DBusError.IOError,
                else => return DBusError.Failed,
            };

            // Check if this message is the reply to our request
            if (incoming.fixed_header.msg_type == .method_return or incoming.fixed_header.msg_type == .error_reply) {
                if (incoming.getReplySerial() == expected_serial) {
                    if (incoming.fixed_header.msg_type == .error_reply) {
                        return mapDBusError(incoming.getErrorName());
                    }
                    return incoming;
                }
            }

            // Other message (e.g. BlueZ signal or another reply) -> push to queue!
            self.incoming_queue.append(incoming) catch {
                incoming.deinit();
                return DBusError.NoMemory;
            };
        }
    }

    /// Convenient wrapper for RPC method calls.
    pub fn callMethod(
        self: *Connection,
        dest: [:0]const u8,
        path: [:0]const u8,
        iface: [:0]const u8,
        method: [:0]const u8,
        timeout_ms: i32,
    ) DBusError!Message {
        var msg = try createMethodCall(dest, path, iface, method);
        defer msg.deinit();
        return self.sendMessage(&msg, timeout_ms);
    }

    /// Registers a well-known name on the D-Bus bus.
    pub fn requestName(self: *Connection, name: [:0]const u8, flags: u32) DBusError!RequestNameReply {
        var msg = try createMethodCall(
            "org.freedesktop.DBus",
            "/org/freedesktop/DBus",
            "org.freedesktop.DBus",
            "RequestName",
        );
        defer msg.deinit();

        var b = msg.builder();
        b.appendString(name) catch return DBusError.NoMemory;
        b.appendUInt32(flags) catch return DBusError.NoMemory;

        var reply = try self.sendMessage(&msg, 5000);
        defer reply.deinit();

        var it = reply.iterator();
        const code = it.getUInt32() orelse return DBusError.Failed;
        return @enumFromInt(code);
    }

    /// Releases a previously requested well-known bus name.
    pub fn releaseName(self: *Connection, name: [:0]const u8) DBusError!ReleaseNameReply {
        var msg = try createMethodCall(
            "org.freedesktop.DBus",
            "/org/freedesktop/DBus",
            "org.freedesktop.DBus",
            "ReleaseName",
        );
        defer msg.deinit();

        var b = msg.builder();
        b.appendString(name) catch return DBusError.NoMemory;

        var reply = try self.sendMessage(&msg, 5000);
        defer reply.deinit();

        var it = reply.iterator();
        const code = it.getUInt32() orelse return DBusError.Failed;
        return @enumFromInt(code);
    }

    /// Registers a D-Bus match rule with the D-Bus daemon.
    pub fn addMatch(self: *Connection, rule: [:0]const u8) DBusError!void {
        var msg = try createMethodCall(
            "org.freedesktop.DBus",
            "/org/freedesktop/DBus",
            "org.freedesktop.DBus",
            "AddMatch",
        );
        defer msg.deinit();

        var b = msg.builder();
        b.appendString(rule) catch return DBusError.NoMemory;

        var reply = try self.sendMessage(&msg, 5000);
        defer reply.deinit();
    }

    /// Removes a previously registered D-Bus match rule from the D-Bus daemon.
    pub fn removeMatch(self: *Connection, rule: [:0]const u8) DBusError!void {
        var msg = try createMethodCall(
            "org.freedesktop.DBus",
            "/org/freedesktop/DBus",
            "org.freedesktop.DBus",
            "RemoveMatch",
        );
        defer msg.deinit();

        var b = msg.builder();
        b.appendString(rule) catch return DBusError.NoMemory;

        var reply = try self.sendMessage(&msg, 5000);
        defer reply.deinit();
    }

    /// Pops the next message from the internal receive queue or socket.
    pub fn popMessage(self: *Connection) ?Message {
        self.read_mutex.lock();
        defer self.read_mutex.unlock();
        return self.popMessageUnlocked();
    }

    fn popMessageUnlocked(self: *Connection) ?Message {
        // 1. Service messages from internal queue first
        if (self.queue_head < self.incoming_queue.len) {
            const msg = self.incoming_queue.items[self.queue_head];
            self.queue_head += 1;
            if (self.queue_head >= self.incoming_queue.len) {
                self.incoming_queue.clearRetainingCapacity();
                self.queue_head = 0;
            }
            return msg;
        }

        // 2. If queue is empty, check socket non-blocking
        const has_data = self.socket.pollRead(0) catch return null;
        if (!has_data) return null;

        return self.readNextMessageFromSocket() catch null;
    }

    /// Selectively pops the first message that satisfies the predicate function.
    /// Non-matching messages are preserved in incoming_queue in exact FIFO order (zero loss, zero allocations).
    /// If no matching message is currently queued, polls the socket non-blocking.
    pub fn popMatching(
        self: *Connection,
        context: anytype,
        comptime predicate: fn (@TypeOf(context), *const Message) bool,
    ) ?Message {
        self.read_mutex.lock();
        defer self.read_mutex.unlock();
        return self.popMatchingUnlocked(context, predicate);
    }

    fn popMatchingUnlocked(
        self: *Connection,
        context: anytype,
        comptime predicate: fn (@TypeOf(context), *const Message) bool,
    ) ?Message {
        // 1. Search existing receive queue
        var idx = self.queue_head;
        while (idx < self.incoming_queue.len) : (idx += 1) {
            const candidate = &self.incoming_queue.items[idx];
            if (predicate(context, candidate)) {
                const matched = candidate.*;
                // Remove matched message by shifting subsequent elements forward
                std.mem.copyForwards(Message, self.incoming_queue.items[idx .. self.incoming_queue.len - 1], self.incoming_queue.items[idx + 1 .. self.incoming_queue.len]);
                self.incoming_queue.len -= 1;
                if (self.queue_head >= self.incoming_queue.len) {
                    self.incoming_queue.clearRetainingCapacity();
                    self.queue_head = 0;
                }
                return matched;
            }
        }

        // 2. If no match in queue, check socket non-blocking
        const has_data = self.socket.pollRead(0) catch return null;
        if (!has_data) return null;

        var incoming = self.readNextMessageFromSocket() catch return null;
        if (predicate(context, &incoming)) {
            return incoming;
        }

        // Not a match: preserve in queue so other callers or central event loop can process it
        self.incoming_queue.append(incoming) catch {
            incoming.deinit();
        };
        return null;
    }

    /// Re-inserts an unhandled message back into the receive queue so other components can process it.
    pub fn requeueMessage(self: *Connection, msg: Message) !void {
        self.read_mutex.lock();
        defer self.read_mutex.unlock();
        if (self.queue_head > 0) {
            self.queue_head -= 1;
            self.incoming_queue.items[self.queue_head] = msg;
        } else {
            try self.incoming_queue.append(msg);
        }
    }

    /// Reads incoming data from the D-Bus socket (waits up to timeout_ms).
    pub fn readWrite(self: *Connection, timeout_ms: i32) bool {
        self.read_mutex.lock();
        defer self.read_mutex.unlock();
        return self.readWriteUnlocked(timeout_ms);
    }

    fn readWriteUnlocked(self: *Connection, timeout_ms: i32) bool {
        if (self.queue_head < self.incoming_queue.len) return true;

        const has_data = self.socket.pollRead(timeout_ms) catch return false;
        if (!has_data) return false;

        if (self.readNextMessageFromSocket()) |msg| {
            self.incoming_queue.append(msg) catch {
                var m = msg;
                m.deinit();
                return false;
            };
            return true;
        } else |_| {
            return false;
        }
    }

    /// Waits on the D-Bus socket for new incoming messages up to timeout_ms.
    /// Does not short-circuit on existing unhandled messages in incoming_queue, ensuring caller loops actually wait.
    pub fn pollSocket(self: *Connection, timeout_ms: i32) bool {
        self.read_mutex.lock();
        defer self.read_mutex.unlock();

        const has_data = self.socket.pollRead(timeout_ms) catch return false;
        if (!has_data) return false;

        if (self.readNextMessageFromSocket()) |msg| {
            self.incoming_queue.append(msg) catch {
                var m = msg;
                m.deinit();
                return false;
            };
            return true;
        } else |_| {
            return false;
        }
    }

    pub fn getUnixFd(self: *Connection) ?i32 {
        return self.socket.fd;
    }

    pub fn isConnected(self: *Connection) bool {
        _ = self;
        return true;
    }

    /// Reads a complete D-Bus message strictly conforming to specification.
    /// Captures any transmitted UNIX file descriptors (SCM_RIGHTS).
    fn readNextMessageFromSocket(self: *Connection) !Message {
        var hdr_bytes: [16]u8 = undefined;
        var received_fds: [8]std.posix.fd_t = [_]std.posix.fd_t{-1} ** 8;
        var fds_count: usize = 0;

        if (self.supports_unix_fd) {
            const res = try self.socket.recvWithFds(&hdr_bytes, &received_fds);
            fds_count = res.fds_read;
            if (res.bytes_read < 16) {
                try self.socket.readExact(hdr_bytes[res.bytes_read..16]);
            }
        } else {
            try self.socket.readExact(&hdr_bytes);
        }

        errdefer {
            for (received_fds[0..fds_count]) |fd| {
                if (fd >= 0) {
                    _ = std.posix.system.close(fd);
                }
            }
        }

        const fixed_hdr = try FixedHeader.decode(&hdr_bytes);
        const total_size = header.calcTotalMessageSize(fixed_hdr.fields_len, fixed_hdr.body_len);

        var wire_bytes = try ByteBuffer.initCapacity(self.allocator, total_size);
        errdefer wire_bytes.deinit();

        try wire_bytes.appendSlice(&hdr_bytes);

        const remaining_bytes = total_size - 16;
        if (remaining_bytes > 0) {
            try wire_bytes.ensureTotalCapacity(total_size);
            const current_len = wire_bytes.len;
            wire_bytes.len = total_size;
            try self.socket.readExact(wire_bytes.data[current_len..total_size]);
        }

        const hf = try HeaderFields.parse(wire_bytes.getSlice(), fixed_hdr.fields_len);

        var msg = Message{
            .allocator = self.allocator,
            .fixed_header = fixed_hdr,
            .header_fields = hf,
            .wire_bytes = wire_bytes,
            .fd_count = @intCast(fds_count),
        };
        @memcpy(msg.fds[0..fds_count], received_fds[0..fds_count]);

        return msg;
    }

    /// Predefined BlueZ match rules
    pub const BlueZMatchRules = struct {
        pub const properties_changed = "type='signal',sender='org.bluez',interface='org.freedesktop.DBus.Properties',member='PropertiesChanged'";
        pub const interfaces_added = "type='signal',sender='org.bluez',interface='org.freedesktop.DBus.ObjectManager',member='InterfacesAdded'";
        pub const interfaces_removed = "type='signal',sender='org.bluez',interface='org.freedesktop.DBus.ObjectManager',member='InterfacesRemoved'";
    };

    pub fn addBlueZMatchRules(self: *Connection) DBusError!void {
        try self.addMatch(BlueZMatchRules.properties_changed);
        try self.addMatch(BlueZMatchRules.interfaces_added);
        try self.addMatch(BlueZMatchRules.interfaces_removed);
    }
};

fn mapDBusError(error_name: ?[]const u8) DBusError {
    const name = error_name orelse return DBusError.Failed;
    if (std.mem.endsWith(u8, name, "ServiceUnknown")) return DBusError.ServiceUnknown;
    if (std.mem.endsWith(u8, name, "UnknownMethod")) return DBusError.UnknownMethod;
    if (std.mem.endsWith(u8, name, "UnknownObject")) return DBusError.UnknownObject;
    if (std.mem.endsWith(u8, name, "UnknownInterface")) return DBusError.UnknownInterface;
    if (std.mem.endsWith(u8, name, "UnknownProperty")) return DBusError.UnknownProperty;
    if (std.mem.endsWith(u8, name, "PropertyReadOnly")) return DBusError.PropertyReadOnly;
    if (std.mem.endsWith(u8, name, "InvalidArgs")) return DBusError.InvalidArgs;
    if (std.mem.endsWith(u8, name, "AccessDenied")) return DBusError.AccessDenied;
    if (std.mem.endsWith(u8, name, "NoReply")) return DBusError.NoReply;
    if (std.mem.endsWith(u8, name, "Timeout")) return DBusError.Timeout;
    return DBusError.Failed;
}

test "Connection: Mutex mutual exclusion" {
    var mutex = Mutex{};
    try std.testing.expect(mutex.tryLock());
    try std.testing.expect(!mutex.tryLock());
    mutex.unlock();
    try std.testing.expect(mutex.tryLock());
    mutex.unlock();

    var counter: u32 = 0;
    const Worker = struct {
        fn run(m: *Mutex, c: *u32) void {
            for (0..1000) |_| {
                m.lock();
                c.* += 1;
                m.unlock();
            }
        }
    };

    var t1 = try std.Thread.spawn(.{}, Worker.run, .{ &mutex, &counter });
    var t2 = try std.Thread.spawn(.{}, Worker.run, .{ &mutex, &counter });
    var t3 = try std.Thread.spawn(.{}, Worker.run, .{ &mutex, &counter });
    var t4 = try std.Thread.spawn(.{}, Worker.run, .{ &mutex, &counter });

    t1.join();
    t2.join();
    t3.join();
    t4.join();

    try std.testing.expectEqual(@as(u32, 4000), counter);
}

