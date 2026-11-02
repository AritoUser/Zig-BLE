//! Blocking mutex shared by the backends, the event loop and the D-Bus connection.
//!
//! Waiting threads sleep in the kernel instead of spinning: futex on Linux, SRW lock on
//! Windows, `os_unfair_lock` on Darwin. Other targets fall back to a spin loop that yields.
//! The mutex is not reentrant and needs no initialization beyond `.{}`.

const std = @import("std");
const builtin = @import("builtin");

pub const Mutex = switch (builtin.os.tag) {
    .linux => FutexMutex,
    .windows => SrwMutex,
    .macos, .ios, .tvos, .watchos, .visionos => UnfairMutex,
    else => YieldMutex,
};

const FutexMutex = struct {
    state: std.atomic.Value(u32) = .init(unlocked),

    const unlocked: u32 = 0;
    const locked: u32 = 1;
    const contended: u32 = 2;

    pub fn lock(self: *FutexMutex) void {
        if (self.state.cmpxchgStrong(unlocked, locked, .acquire, .monotonic) == null) return;
        // Mark the lock contended so `unlock` knows to wake a sleeper, then sleep until free.
        while (self.state.swap(contended, .acquire) != unlocked) {
            _ = std.os.linux.futex_4arg(&self.state.raw, .{ .cmd = .WAIT, .private = true }, contended, null);
        }
    }

    pub fn tryLock(self: *FutexMutex) bool {
        return self.state.cmpxchgStrong(unlocked, locked, .acquire, .monotonic) == null;
    }

    pub fn unlock(self: *FutexMutex) void {
        if (self.state.swap(unlocked, .release) == contended) {
            _ = std.os.linux.futex_3arg(&self.state.raw, .{ .cmd = .WAKE, .private = true }, 1);
        }
    }
};

const SrwMutex = struct {
    srw: std.os.windows.SRWLOCK = .{},

    pub fn lock(self: *SrwMutex) void {
        std.os.windows.ntdll.RtlAcquireSRWLockExclusive(&self.srw);
    }

    pub fn tryLock(self: *SrwMutex) bool {
        return std.os.windows.ntdll.RtlTryAcquireSRWLockExclusive(&self.srw).toBool();
    }

    pub fn unlock(self: *SrwMutex) void {
        std.os.windows.ntdll.RtlReleaseSRWLockExclusive(&self.srw);
    }
};

const UnfairMutex = struct {
    oul: std.c.os_unfair_lock = .{},

    pub fn lock(self: *UnfairMutex) void {
        std.c.os_unfair_lock_lock(&self.oul);
    }

    pub fn tryLock(self: *UnfairMutex) bool {
        return std.c.os_unfair_lock_trylock(&self.oul);
    }

    pub fn unlock(self: *UnfairMutex) void {
        std.c.os_unfair_lock_unlock(&self.oul);
    }
};

const YieldMutex = struct {
    locked: std.atomic.Value(bool) = .init(false),

    pub fn lock(self: *YieldMutex) void {
        while (self.locked.cmpxchgWeak(false, true, .acquire, .monotonic) != null) {
            std.Thread.yield() catch std.atomic.spinLoopHint();
        }
    }

    pub fn tryLock(self: *YieldMutex) bool {
        return self.locked.cmpxchgStrong(false, true, .acquire, .monotonic) == null;
    }

    pub fn unlock(self: *YieldMutex) void {
        self.locked.store(false, .release);
    }
};

test "Mutex serializes concurrent increments" {
    if (builtin.single_threaded) return error.SkipZigTest;

    const Shared = struct {
        mutex: Mutex = .{},
        counter: usize = 0,

        fn work(self: *@This()) void {
            for (0..10_000) |_| {
                self.mutex.lock();
                defer self.mutex.unlock();
                self.counter += 1;
            }
        }
    };

    var shared: Shared = .{};
    var threads: [4]std.Thread = undefined;
    for (&threads) |*t| t.* = try std.Thread.spawn(.{}, Shared.work, .{&shared});
    for (threads) |t| t.join();
    try std.testing.expectEqual(@as(usize, 40_000), shared.counter);

    try std.testing.expect(shared.mutex.tryLock());
    try std.testing.expect(!shared.mutex.tryLock());
    shared.mutex.unlock();
}
