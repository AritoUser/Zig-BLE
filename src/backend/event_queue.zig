//! # Pull-style event queue
//!
//! Collects scan results, notifications and connection events in a fixed-size ring buffer,
//! so an application can handle them in one loop with `next()` / `wait()` instead of
//! writing callbacks. The callbacks only copy the event into the queue; they may run on
//! backend threads (WinRT), which the queue's mutex accounts for.
//!
//! ```zig
//! var queue: ble.EventQueue(.{}) = .{};
//! try queue.startScan(&adapter, .{});
//! while (queue.wait(&adapter, 100)) |event| switch (event) {
//!     .device_discovered => |dev| ...,
//!     .notification => |n| ...,
//!     .connection => |c| ...,
//! };
//! ```

const std = @import("std");
const types = @import("types.zig");
const unified = @import("unified.zig");

const Address = types.Address;
const UUID = types.UUID;
const BleError = types.BleError;
const ScanFilter = types.ScanFilter;
const DiscoveredDevice = types.DiscoveredDevice;
const CharacteristicSelector = types.CharacteristicSelector;
const ConnectionEvent = types.ConnectionEvent;
const UnifiedAdapter = unified.UnifiedAdapter;
const UnifiedDevice = unified.UnifiedDevice;

pub const EventQueueConfig = struct {
    /// Events held before the oldest is dropped (see `dropped`).
    capacity: usize = 64,
    /// Notification payload bytes kept per event; longer values are truncated.
    max_value_len: usize = 244,
    /// Concurrent subscriptions made through `subscribe`.
    max_subscriptions: usize = 16,
};

pub fn EventQueue(comptime config: EventQueueConfig) type {
    return struct {
        const Self = @This();

        pub const Notification = struct {
            device: Address,
            uuid: UUID,
            value_buf: [config.max_value_len]u8 = undefined,
            value_len: u16 = 0,
            /// The value was longer than `max_value_len`.
            truncated: bool = false,

            pub fn value(self: *const Notification) []const u8 {
                return self.value_buf[0..self.value_len];
            }
        };

        pub const Event = union(enum) {
            device_discovered: DiscoveredDevice,
            notification: Notification,
            connection: ConnectionEvent,
        };

        const Subscription = struct {
            queue: *Self,
            device: Address,
            char: CharacteristicSelector,
        };

        mutex: types.SyncMutex = .{},
        items: [config.capacity]Event = undefined,
        head: usize = 0,
        len: usize = 0,
        /// Events lost because the queue was full; the oldest event is dropped first.
        dropped: usize = 0,
        subscriptions: [config.max_subscriptions]Subscription = undefined,
        subscriptions_used: [config.max_subscriptions]bool = @splat(false),

        /// Starts scanning with results delivered to this queue.
        pub fn startScan(self: *Self, adapter: *UnifiedAdapter, filter: ScanFilter) BleError!void {
            return adapter.startScan(filter, onScan, self);
        }

        /// Subscribes to `char` (a `UUID` or `CharacteristicSelector`) with notifications
        /// delivered to this queue, tagged with the device address.
        pub fn subscribe(self: *Self, dev: *UnifiedDevice, char: anytype) BleError!void {
            const sel = CharacteristicSelector.from(char);
            const index = blk: {
                self.mutex.lock();
                defer self.mutex.unlock();
                for (&self.subscriptions, &self.subscriptions_used, 0..) |*sub, *used, i| {
                    if (!used.*) {
                        used.* = true;
                        sub.* = .{ .queue = self, .device = dev.address, .char = sel };
                        break :blk i;
                    }
                }
                return BleError.PoolExhausted;
            };
            dev.subscribe(sel, onNotification, &self.subscriptions[index]) catch |err| {
                self.mutex.lock();
                defer self.mutex.unlock();
                self.subscriptions_used[index] = false;
                return err;
            };
        }

        /// Ends a subscription made with `subscribe` and frees its slot.
        pub fn unsubscribe(self: *Self, dev: *UnifiedDevice, char: anytype) BleError!void {
            const sel = CharacteristicSelector.from(char);
            try dev.unsubscribe(sel);
            self.mutex.lock();
            defer self.mutex.unlock();
            for (&self.subscriptions, &self.subscriptions_used) |*sub, *used| {
                if (used.* and sub.device.eql(dev.address) and std.meta.eql(sub.char, sel)) used.* = false;
            }
        }

        /// Frees the subscription slots of `device`, e.g. after disconnecting it.
        pub fn releaseDevice(self: *Self, device: Address) void {
            self.mutex.lock();
            defer self.mutex.unlock();
            for (&self.subscriptions, &self.subscriptions_used) |*sub, *used| {
                if (used.* and sub.device.eql(device)) used.* = false;
            }
        }

        /// Callback for backend-specific connection event setters, e.g.
        /// `backend.setConnectionEventCallback(Queue.onConnectionEvent, &queue)`.
        pub fn onConnectionEvent(event: ConnectionEvent, user_data: ?*anyopaque) void {
            const self: *Self = @ptrCast(@alignCast(user_data orelse return));
            self.push(.{ .connection = event });
        }

        /// Returns the oldest queued event, or null if there is none.
        pub fn next(self: *Self) ?Event {
            self.mutex.lock();
            defer self.mutex.unlock();
            if (self.len == 0) return null;
            const event = self.items[self.head];
            self.head = (self.head + 1) % config.capacity;
            self.len -= 1;
            return event;
        }

        /// Returns the next event, calling `adapter.processEvents` (up to `timeout_ms`) if the
        /// queue is empty. Returns null when nothing arrived in time.
        pub fn wait(self: *Self, adapter: *UnifiedAdapter, timeout_ms: u32) ?Event {
            if (self.next()) |event| return event;
            adapter.processEvents(timeout_ms) catch return null;
            return self.next();
        }

        pub fn push(self: *Self, event: Event) void {
            self.mutex.lock();
            defer self.mutex.unlock();
            if (self.len == config.capacity) {
                self.head = (self.head + 1) % config.capacity;
                self.len -= 1;
                self.dropped += 1;
            }
            self.items[(self.head + self.len) % config.capacity] = event;
            self.len += 1;
        }

        fn onScan(device: *const DiscoveredDevice, user_data: ?*anyopaque) void {
            const self: *Self = @ptrCast(@alignCast(user_data orelse return));
            self.push(.{ .device_discovered = device.* });
        }

        fn onNotification(uuid: UUID, data: []const u8, user_data: ?*anyopaque) void {
            const sub: *Subscription = @ptrCast(@alignCast(user_data orelse return));
            var n = Notification{ .device = sub.device, .uuid = uuid };
            const len = @min(data.len, config.max_value_len);
            @memcpy(n.value_buf[0..len], data[0..len]);
            n.value_len = @intCast(len);
            n.truncated = data.len > config.max_value_len;
            sub.queue.push(.{ .notification = n });
        }
    };
}

test "EventQueue collects scan results and notifications from the mock backend" {
    const mock_mod = @import("mock/mod.zig");
    var mock = mock_mod.MockController.init();
    var adapter = UnifiedAdapter.init(mock.asBackend());
    try adapter.setPowered(true);

    const addr = Address{ .bytes = [_]u8{ 0x11, 0x22, 0x33, 0x44, 0x55, 0x99 } };
    var dev = mock_mod.MockDevice{ .address = addr };
    dev.setName("Sensor");
    _ = dev.addCharacteristic(.{ .uuid = UUID.from16(0x2A37) });
    _ = try mock.addDevice(dev);

    var queue: EventQueue(.{ .capacity = 4, .max_value_len = 2 }) = .{};
    try queue.startScan(&adapter, .{});
    const found = queue.next().?;
    try std.testing.expectEqualStrings("Sensor", found.device_discovered.getName().?);
    try std.testing.expect(queue.next() == null);

    var connected = try adapter.connect(addr, 1000);
    try queue.subscribe(&connected, UUID.from16(0x2A37));
    try mock.triggerNotification(addr, UUID.from16(0x2A37), &.{ 0x00, 72, 0xFF });
    const ev = queue.wait(&adapter, 0).?;
    try std.testing.expect(ev.notification.device.eql(addr));
    try std.testing.expectEqualSlices(u8, &.{ 0x00, 72 }, ev.notification.value());
    try std.testing.expect(ev.notification.truncated);

    // A full queue drops the oldest event
    for (0..5) |i| try mock.triggerNotification(addr, UUID.from16(0x2A37), &.{@intCast(i)});
    try std.testing.expectEqual(@as(usize, 1), queue.dropped);
    try std.testing.expectEqual(@as(u8, 1), queue.next().?.notification.value()[0]);

    @TypeOf(queue).onConnectionEvent(.{ .disconnected = .{ .address = addr, .reason_code = null } }, &queue);
    try std.testing.expect(queue.next().? == .notification);
    var last: @TypeOf(queue).Event = undefined;
    while (queue.next()) |e| last = e;
    try std.testing.expect(last == .connection);

    try queue.unsubscribe(&connected, UUID.from16(0x2A37));
    try std.testing.expect(!queue.subscriptions_used[0]);
    queue.releaseDevice(addr);
}
