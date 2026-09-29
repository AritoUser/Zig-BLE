//! Zig-BLE EventLoop: Universal, allocation-free background worker for D-Bus I/O.
//! Enables non-blocking BLE Central and Peripheral operation in a separate std.Thread.

const std = @import("std");
const builtin = @import("builtin");
const linux = if (builtin.os.tag == .linux) std.os.linux else struct {};

const dbus = if (builtin.os.tag == .linux) @import("dbus/mod.zig") else struct {};
const Connection = if (builtin.os.tag == .linux) dbus.Connection else struct {};
const Message = if (builtin.os.tag == .linux) dbus.Message else struct {};

/// Universal, type-preserving message handler wrapper with zero heap allocations.
pub const MessageHandler = struct {
    ctx: *anyopaque,
    handleFn: *const fn (ctx: *anyopaque, msg: *const Message) bool,

    pub fn init(pointer: anytype, comptime method: anytype) MessageHandler {
        const Ptr = @TypeOf(pointer);
        const PtrInfo = @typeInfo(Ptr);
        std.debug.assert(PtrInfo == .pointer);

        const gen = struct {
            fn wrapper(ctx: *anyopaque, msg: *const Message) bool {
                const self: Ptr = @ptrCast(@alignCast(ctx));
                return @call(.auto, method, .{ self, msg }) catch false;
            }
        };

        return .{
            .ctx = pointer,
            .handleFn = gen.wrapper,
        };
    }
};

/// Multi-handler EventLoop for non-blocking I/O via Linux epoll.
pub const EventLoop = struct {
    conn: *Connection,
    handlers: [8]MessageHandler = undefined,
    handler_count: usize = 0,

    thread: ?std.Thread = null,
    should_stop: std.atomic.Value(bool) = std.atomic.Value(bool).init(false),
    is_running: bool = false,
    epoll_fd: i32 = -1,
    wake_fd: i32 = -1,

    pub fn init(conn: *Connection) EventLoop {
        return .{
            .conn = conn,
        };
    }

    /// Registers a message handler in the loop.
    pub fn addHandler(self: *EventLoop, handler: MessageHandler) !void {
        if (self.handler_count >= self.handlers.len) return error.MaxHandlersReached;
        self.handlers[self.handler_count] = handler;
        self.handler_count += 1;
    }

    /// Runs a single I/O step (useful for manual stepping).
    pub fn step(self: *EventLoop, timeout_ms: i32) void {
        if (builtin.os.tag != .linux) return;

        _ = self.conn.pollSocket(timeout_ms);
        while (self.conn.popMessage()) |msg| {
            defer msg.deinit();
            for (self.handlers[0..self.handler_count]) |h| {
                if (h.handleFn(h.ctx, &msg)) break;
            }
        }
    }

    fn worker(self: *EventLoop) void {
        if (builtin.os.tag == .linux and self.epoll_fd >= 0) {
            var events: [8]linux.epoll_event = undefined;
            while (!self.should_stop.load(.acquire)) {
                // Sleeps at 0% CPU load and wakes immediately when the kernel receives data
                const count = linux.epoll_wait(self.epoll_fd, &events, events.len, 500);
                if (self.should_stop.load(.acquire)) break;

                if (count > 0) {
                    _ = self.conn.readWrite(0);
                    while (self.conn.popMessage()) |msg| {
                        defer msg.deinit();
                        for (self.handlers[0..self.handler_count]) |h| {
                            if (h.handleFn(h.ctx, &msg)) break;
                        }
                    }
                }
            }
        } else {
            while (!self.should_stop.load(.acquire)) {
                self.step(50);
            }
        }
    }

    /// Starts the event loop in a separate background thread (std.Thread).
    /// Configures epoll_wait and eventfd for 0% idle CPU and microsecond response time.
    pub fn start(self: *EventLoop) !void {
        if (self.is_running) return;
        self.should_stop.store(false, .release);

        if (builtin.os.tag == .linux) {
            const epfd_res = linux.epoll_create1(linux.EPOLL.CLOEXEC);
            const epfd: i32 = @intCast(epfd_res);
            if (epfd >= 0) {
                const wfd_res = linux.eventfd(0, linux.EFD.CLOEXEC | linux.EFD.NONBLOCK);
                const wfd: i32 = @intCast(wfd_res);
                if (wfd >= 0) {
                    var wake_ev = linux.epoll_event{
                        .events = linux.EPOLL.IN,
                        .data = .{ .fd = wfd },
                    };
                    _ = linux.epoll_ctl(epfd, linux.EPOLL.CTL_ADD, wfd, &wake_ev);
                    self.wake_fd = wfd;
                }

                if (self.conn.getUnixFd()) |dbus_fd| {
                    var dbus_ev = linux.epoll_event{
                        .events = linux.EPOLL.IN | linux.EPOLL.ERR | linux.EPOLL.HUP,
                        .data = .{ .fd = dbus_fd },
                    };
                    _ = linux.epoll_ctl(epfd, linux.EPOLL.CTL_ADD, dbus_fd, &dbus_ev);
                }
                self.epoll_fd = epfd;
            }
        }

        self.thread = try std.Thread.spawn(.{}, worker, .{self});
        self.is_running = true;
    }

    /// Stops the background thread and wakes epoll via eventfd with zero microsecond latency.
    pub fn stop(self: *EventLoop) void {
        if (!self.is_running) return;
        self.should_stop.store(true, .release);

        // Instant wakeup signal to the epoll_wait descriptor
        if (builtin.os.tag == .linux and self.wake_fd >= 0) {
            const val: u64 = 1;
            _ = linux.write(self.wake_fd, std.mem.asBytes(&val).ptr, 8);
        }

        if (self.thread) |t| {
            t.join();
            self.thread = null;
        }

        if (builtin.os.tag == .linux) {
            if (self.wake_fd >= 0) {
                _ = linux.close(self.wake_fd);
                self.wake_fd = -1;
            }
            if (self.epoll_fd >= 0) {
                _ = linux.close(self.epoll_fd);
                self.epoll_fd = -1;
            }
        }

        self.is_running = false;
    }
};

// ============================================================================
// Unit Tests
// ============================================================================

test "EventLoop: initialization and handler registration" {
    var dummy_conn: Connection = undefined;
    var loop = EventLoop.init(&dummy_conn);
    try std.testing.expectEqual(@as(usize, 0), loop.handler_count);
    try std.testing.expect(!loop.is_running);

    const DummyTarget = struct {
        called: bool = false,
        fn handle(self: *@This(), _: *const Message) !bool {
            self.called = true;
            return true;
        }
    };

    var target = DummyTarget{};
    const h = MessageHandler.init(&target, DummyTarget.handle);
    try loop.addHandler(h);
    try std.testing.expectEqual(@as(usize, 1), loop.handler_count);
}
