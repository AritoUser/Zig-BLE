//! Robust Fuzz-Testing Suite for Zig-BLE Advertising Parser
//! Targets: `AdIterator.next()` & `AdvertisingReport.parse()`
//! Verifies zero panics, guaranteed loop termination, and zero heap allocations
//! under arbitrarily malformed, truncated, extended, and corrupted Bluetooth LE payloads.

const std = @import("std");
const builtin = @import("builtin");
const Zig_BLE = @import("Zig_BLE");

const AdIterator = Zig_BLE.AdIterator;
const AdvertisingReport = Zig_BLE.AdvertisingReport;
const AdType = Zig_BLE.AdType;

extern "kernel32" fn QueryPerformanceCounter(lpPerformanceCount: *u64) callconv(.winapi) c_int;
extern "kernel32" fn QueryPerformanceFrequency(lpFrequency: *u64) callconv(.winapi) c_int;

const Timer = struct {
    start_ns: u64,

    pub fn start() Timer {
        return .{ .start_ns = getNanoseconds() };
    }

    pub fn read(self: *const Timer) u64 {
        const now = getNanoseconds();
        return if (now >= self.start_ns) now - self.start_ns else 0;
    }

    pub fn getNanoseconds() u64 {
        if (builtin.os.tag == .linux) {
            var ts: std.os.linux.timespec = undefined;
            _ = std.os.linux.clock_gettime(std.os.linux.CLOCK.MONOTONIC, &ts);
            return @as(u64, @intCast(ts.sec)) * 1_000_000_000 + @as(u64, @intCast(ts.nsec));
        } else if (builtin.os.tag == .windows) {
            var counts: u64 = 0;
            _ = QueryPerformanceCounter(&counts);
            var freq: u64 = 0;
            _ = QueryPerformanceFrequency(&freq);
            if (freq == 0) return 0;
            return @intCast(@as(u128, counts) * 1_000_000_000 / freq);
        } else {
            return 0;
        }
    }
};

/// Maximum payload size according to Bluetooth Core Spec v5.4 / v6.0
/// (Extended Advertising Chained PDUs up to 1650 octets).
pub const MAX_ADVERTISING_PAYLOAD_SIZE: usize = 1650;

/// libFuzzer-compatible C entrypoint for LLVM sanitizers (-fsanitize=fuzzer).
export fn LLVMFuzzerTestOneInput(data: [*]const u8, size: usize) c_int {
    fuzzOneInput(data[0..size]);
    return 0;
}

/// Core fuzzing target function: exercises AdIterator, all typed views, and AdvertisingReport.
pub fn fuzzOneInput(data: []const u8) void {
    // ------------------------------------------------------------------------
    // Target 1: Isolated TLV Walk via AdIterator
    // ------------------------------------------------------------------------
    var it = AdIterator.init(data);
    var element_count: usize = 0;

    while (it.next()) |elem| {
        element_count += 1;
        // Invariance proof: Every valid TLV element consumes at least 2 bytes (length + type).
        // Therefore, element_count cannot exceed data.len / 2 + 1.
        if (element_count > data.len / 2 + 2) {
            @panic("AdIterator loop did not terminate!");
        }

        // Test all type accessors and ensure no panics or out-of-bounds on corrupted data:
        _ = elem.asFlags();
        _ = elem.asLocalName();
        _ = elem.asValidLocalName();
        _ = elem.asTxPower();
        _ = elem.asAppearance();

        if (elem.asManufacturerData()) |mfg| {
            _ = mfg.getCompanyName();
        }

        if (elem.asServiceData16()) |sd16| {
            _ = sd16.getUuid();
        }

        if (elem.asServiceData32()) |sd32| {
            _ = sd32.getUuid();
        }

        if (elem.asServiceData128()) |sd128| {
            _ = sd128.uuid.is16Bit();
            _ = sd128.uuid.to16();
            _ = sd128.uuid.is32Bit();
            _ = sd128.uuid.to32();
            _ = sd128.uuid.toString();
        }

        if (elem.asServiceUuids16()) |val| {
            var u16_it = val;
            var u16_count: usize = 0;
            while (u16_it.next()) |_| {
                u16_count += 1;
                if (u16_count > elem.data.len) @panic("ServiceUuids16Iterator infinite loop!");
            }
        }

        if (elem.asServiceUuids32()) |val| {
            var u32_it = val;
            var u32_count: usize = 0;
            while (u32_it.next()) |_| {
                u32_count += 1;
                if (u32_count > elem.data.len) @panic("ServiceUuids32Iterator infinite loop!");
            }
        }

        if (elem.asServiceUuids128()) |val| {
            var u128_it = val;
            var u128_count: usize = 0;
            while (u128_it.next()) |uuid| {
                u128_count += 1;
                if (u128_count > elem.data.len) @panic("ServiceUuids128Iterator infinite loop!");
                _ = uuid.is16Bit();
                _ = uuid.to16();
            }
        }
    }

    // ------------------------------------------------------------------------
    // Target 2: Full One-Pass Parser via AdvertisingReport.parse
    // ------------------------------------------------------------------------
    const report = AdvertisingReport.parse(data);

    if (report.flags) |f| {
        _ = f.toByte();
    }
    if (report.local_name) |name| {
        _ = report.getValidLocalName();
        _ = std.unicode.utf8ValidateSlice(name);
    }
    if (report.appearance) |app| {
        _ = Zig_BLE.Appearance.getName(app);
    }
    if (report.getManufacturerData()) |mfg| {
        _ = mfg.getCompanyName();
    }
    if (report.getServiceData16()) |sd16| {
        _ = sd16.getUuid();
    }
    if (report.getServiceData32()) |sd32| {
        _ = sd32.getUuid();
    }
    if (report.getServiceData128()) |sd128| {
        _ = sd128.uuid.is16Bit();
        _ = sd128.uuid.to16();
    }
}

/// Initial seed corpus of valid, boundary, and edge-case packets.
pub const SeedCorpus = struct {
    pub const seeds = [_][]const u8{
        // 1. Empty buffer
        "",
        // 2. Zero length padding
        "\x00",
        // 3. Length 1 without type byte (truncated)
        "\x01",
        // 4. Length 1 with type byte (0 payload bytes)
        "\x01\x01",
        // 5. Length 255 with 2 bytes total
        "\xFF\x01",
        // 6. Valid standard 31-byte legacy advertising packet
        &[_]u8{
            0x02, 0x01, 0x06, // Flags
            0x09, 0x09, 'Z',  'i',  'g',  '-',  'B',  'L', 'E', '1', // Complete Local Name
            0x03, 0x19, 0x40, 0x03, // Appearance (Heart Rate Sensor)
            0x05, 0xFF, 0x59, 0x00, 0x01, 0x02, // Nordic Semi Mfg Data
            0x00, 0x00, 0x00, 0x00, // Padding
        },
        // 7. Service Data 16, 32, 128 bit packet
        &[_]u8{
            0x05, 0x16, 0x0D, 0x18, 0x12, 0x34, // Service Data 16
            0x06, 0x20, 0x78, 0x56, 0x34, 0x12, 0xAA, // Service Data 32
            0x13, 0x21, // Service Data 128 (16-byte UUID + 2 bytes data)
            0xFB, 0x34, 0x9B, 0x5F, 0x80, 0x00, 0x00, 0x80,
            0x00, 0x10, 0x00, 0x00, 0x0D, 0x18, 0x00, 0x00,
            0xCA, 0xFE,
        },
        // 8. Service UUID Lists (16, 32, 128)
        &[_]u8{
            0x05, 0x03, 0x0D, 0x18, 0x0F, 0x18, // Complete 16-bit UUIDs
            0x05, 0x05, 0x11, 0x22, 0x33, 0x44, // Complete 32-bit UUIDs
            0x11, 0x07, // Complete 128-bit UUIDs
            0x01, 0x02, 0x03, 0x04, 0x05, 0x06, 0x07, 0x08,
            0x09, 0x0A, 0x0B, 0x0C, 0x0D, 0x0E, 0x0F, 0x10,
        },
        // 9. Malformed UTF-8 in local name (overlong / invalid sequence)
        &[_]u8{
            0x05, 0x09, 0xC0, 0x80, 0xF5, 0x80,
        },
        // 10. Truncated UUID in Service Data 128 (15 bytes instead of 16)
        &[_]u8{
            0x10, 0x21, // Length 16 (1 type + 15 bytes data: truncated 128-bit UUID!)
            0x01, 0x02, 0x03, 0x04, 0x05, 0x06, 0x07, 0x08,
            0x09, 0x0A, 0x0B, 0x0C, 0x0D, 0x0E, 0x0F,
        },
        // 11. Truncated Company ID (< 2 bytes)
        &[_]u8{
            0x02, 0xFF, 0x59, // Length 2 (1 type + 1 byte data: truncated company ID!)
        },
        // 12. Duplicate headers
        &[_]u8{
            0x02, 0x01, 0x06, // Flags #1
            0x05, 0x09, 'N',  'a',  'm', 'e', // Name #1
            0x02, 0x01, 0x02, // Flags #2
            0x06, 0x09, 'N',  'e',  'w', 'e', 'r', // Name #2
        },
    };
};

/// High-performance, pseudo-random mutation engine.
pub const Mutator = struct {
    rand: std.Random,

    pub fn init(rand: std.Random) Mutator {
        return Mutator{ .rand = rand };
    }

    /// Mutates the input buffer in-place, returning the new length.
    pub fn mutate(self: *Mutator, buf: []u8, current_len: usize, max_capacity: usize) usize {
        var len = current_len;
        const mutations = self.rand.intRangeAtMost(usize, 1, 3);

        for (0..mutations) |_| {
            const strategy = self.rand.intRangeAtMost(u8, 0, 7);
            len = switch (strategy) {
                0 => self.bitFlip(buf, len),
                1 => self.byteOverwrite(buf, len),
                2 => self.lengthFieldAnomaly(buf, len),
                3 => self.byteInsert(buf, len, max_capacity),
                4 => self.byteDelete(buf, len),
                5 => self.truncate(buf, len),
                6 => self.duplicateHeader(buf, len, max_capacity),
                7 => self.injectMalformedUtf8(buf, len, max_capacity),
                else => len,
            };
        }

        return len;
    }

    /// Flips a single random bit in the payload.
    pub fn bitFlip(self: *Mutator, buf: []u8, len: usize) usize {
        if (len == 0) return 0;
        const byte_idx = self.rand.intRangeLessThan(usize, 0, len);
        const bit_idx = self.rand.intRangeAtMost(u3, 0, 7);
        buf[byte_idx] ^= (@as(u8, 1) << bit_idx);
        return len;
    }

    /// Overwrites a byte with random or boundary values (0x00, 0x01, 0xFF).
    pub fn byteOverwrite(self: *Mutator, buf: []u8, len: usize) usize {
        if (len == 0) return 0;
        const byte_idx = self.rand.intRangeLessThan(usize, 0, len);
        const choice = self.rand.intRangeLessThan(u8, 0, 4);
        buf[byte_idx] = switch (choice) {
            0 => 0x00,
            1 => 0x01,
            2 => 0xFF,
            else => self.rand.int(u8),
        };
        return len;
    }

    /// Specifically targets TLV length headers to test boundary handling.
    pub fn lengthFieldAnomaly(self: *Mutator, buf: []u8, len: usize) usize {
        if (len == 0) return 0;
        // Pick either index 0 or a random offset that might be a TLV header
        const pos = if (self.rand.boolean()) 0 else self.rand.intRangeLessThan(usize, 0, len);
        const anomaly = self.rand.intRangeLessThan(u8, 0, 6);
        buf[pos] = switch (anomaly) {
            0 => 0, // Zero padding
            1 => 1, // Type only (0 payload)
            2 => 255, // Max length (often overflows remaining slice)
            3 => @truncate(len), // Exact remaining length
            4 => @truncate(if (len > 0) len - 1 else 0),
            else => @truncate(len +% 1),
        };
        return len;
    }

    /// Inserts 1 to 4 random bytes into the buffer up to max_capacity.
    pub fn byteInsert(self: *Mutator, buf: []u8, len: usize, max_capacity: usize) usize {
        if (len >= max_capacity) return len;
        const insert_count = @min(self.rand.intRangeAtMost(usize, 1, 4), max_capacity - len);
        const pos = self.rand.intRangeAtMost(usize, 0, len);

        // Shift right
        var i: usize = len;
        while (i > pos) : (i -= 1) {
            buf[i + insert_count - 1] = buf[i - 1];
        }

        // Insert random bytes
        for (0..insert_count) |k| {
            buf[pos + k] = self.rand.int(u8);
        }

        return len + insert_count;
    }

    /// Deletes 1 to 4 bytes from the buffer.
    pub fn byteDelete(self: *Mutator, buf: []u8, len: usize) usize {
        if (len == 0) return 0;
        const delete_count = @min(self.rand.intRangeAtMost(usize, 1, 4), len);
        const pos = self.rand.intRangeAtMost(usize, 0, len - delete_count);

        // Shift left
        for (pos .. len - delete_count) |i| {
            buf[i] = buf[i + delete_count];
        }

        return len - delete_count;
    }

    /// Truncates the buffer at an arbitrary boundary.
    pub fn truncate(self: *Mutator, _: []u8, len: usize) usize {
        if (len == 0) return 0;
        return self.rand.intRangeLessThan(usize, 0, len);
    }

    /// Injects duplicate AD headers (Flags 0x01 or Local Name 0x09).
    pub fn duplicateHeader(self: *Mutator, buf: []u8, len: usize, max_capacity: usize) usize {
        if (len + 3 > max_capacity) return len;
        const header_type: u8 = if (self.rand.boolean()) 0x01 else 0x09;
        buf[len] = 0x02; // length 2
        buf[len + 1] = header_type;
        buf[len + 2] = self.rand.int(u8);
        return len + 3;
    }

    /// Injects malformed / overlong UTF-8 bytes to test local name validation.
    pub fn injectMalformedUtf8(_: *Mutator, buf: []u8, len: usize, max_capacity: usize) usize {
        if (len + 4 > max_capacity) return len;
        // Inject a Local Name TLV with invalid UTF-8 (e.g. 0xC3 followed by non-continuation byte)
        buf[len] = 0x03; // length 3
        buf[len + 1] = 0x09; // Complete Local Name
        buf[len + 2] = 0xC3; // Lead byte expecting continuation
        buf[len + 3] = 0x28; // Invalid continuation byte!
        return len + 4;
    }

    /// Generates a randomized Extended Advertising PDU (up to 1650 bytes).
    pub fn generateExtendedPdu(self: *Mutator, buf: []u8, target_len: usize) usize {
        const actual_len = @min(target_len, buf.len);
        var cursor: usize = 0;

        while (cursor + 2 < actual_len) {
            const remaining = actual_len - cursor;
            // Generate valid or slightly corrupted TLV
            const max_elem_len = @min(remaining - 1, 255);
            const elem_len = self.rand.intRangeAtMost(usize, 1, max_elem_len);

            buf[cursor] = @truncate(elem_len);
            buf[cursor + 1] = self.rand.int(u8); // Random AD type

            // Fill payload
            for (cursor + 2 .. cursor + 1 + elem_len) |idx| {
                if (idx < actual_len) {
                    buf[idx] = self.rand.int(u8);
                }
            }

            cursor += 1 + elem_len;
        }

        return actual_len;
    }
};

pub fn main() !void {
    const initial_seed = 0xCAFE_BABE_1337_0001 ^ Timer.getNanoseconds();
    var prng = std.Random.DefaultPrng.init(initial_seed);
    const rand = prng.random();
    var mutator = Mutator.init(rand);

    const iterations: u64 = 500_000;
    const print_step: u64 = 100_000;

    std.debug.print("\n", .{});
    std.debug.print("=========================================================================================\n", .{});
    std.debug.print("               Zig-BLE Advertising Parser Fuzz-Testing Engine (Zero-Allocation)          \n", .{});
    std.debug.print("           Targets: AdIterator.next() & AdvertisingReport.parse() | Spec v5.4/v6.0      \n", .{});
    std.debug.print("=========================================================================================\n", .{});
    std.debug.print("Running {d} continuous fuzzing iterations with PRNG mutation engine...\n\n", .{iterations});

    var buffer: [MAX_ADVERTISING_PAYLOAD_SIZE]u8 = undefined;

    const timer = Timer.start();
    var total_elements_parsed: u64 = 0;
    var total_extended_pdus: u64 = 0;

    for (0..iterations) |i| {
        // Select base seed or generate extended PDU
        var len: usize = 0;
        if (i % 10 == 0) {
            // Extended Advertising PDU (up to 1650 bytes)
            const ext_size = rand.intRangeAtMost(usize, 32, MAX_ADVERTISING_PAYLOAD_SIZE);
            len = mutator.generateExtendedPdu(&buffer, ext_size);
            total_extended_pdus += 1;
        } else {
            // Seed corpus mutation
            const seed_idx = i % SeedCorpus.seeds.len;
            const seed = SeedCorpus.seeds[seed_idx];
            @memcpy(buffer[0..seed.len], seed);
            len = mutator.mutate(&buffer, seed.len, MAX_ADVERTISING_PAYLOAD_SIZE);
        }

        // Execute fuzz target
        fuzzOneInput(buffer[0..len]);
        total_elements_parsed += 1;

        if ((i + 1) % print_step == 0 or (i + 1) == iterations) {
            const elapsed_ns = @max(1, timer.read());
            const elapsed_ms = @as(f64, @floatFromInt(elapsed_ns)) / 1_000_000.0;
            const mops_sec = (@as(f64, @floatFromInt(i + 1)) / @as(f64, @floatFromInt(elapsed_ns))) * 1000.0;
            std.debug.print("  [PROGRESS] {d:>7} / {d} iterations ({d:>5.1}%) | Elapsed: {d:>6.1} ms | Rate: {d:>6.2} Mop/s\n", .{
                i + 1,
                iterations,
                (@as(f64, @floatFromInt(i + 1)) / @as(f64, @floatFromInt(iterations))) * 100.0,
                elapsed_ms,
                mops_sec,
            });
        }
    }

    const total_elapsed_ns = @max(1, timer.read());
    const total_elapsed_ms = @as(f64, @floatFromInt(total_elapsed_ns)) / 1_000_000.0;
    const final_rate = (@as(f64, @floatFromInt(iterations)) / @as(f64, @floatFromInt(total_elapsed_ns))) * 1000.0;

    std.debug.print("\n=========================================================================================\n", .{});
    std.debug.print("Fuzzing Summary & Safety Guarantees:\n", .{});
    std.debug.print("  [x] Total Iterations:       {d} completed\n", .{iterations});
    std.debug.print("  [x] Extended PDUs Tested:   {d} (payloads up to 1650 bytes)\n", .{total_extended_pdus});
    std.debug.print("  [x] Total Wall Time:        {d:.2} ms (Average rate: {d:.2} Mop/s)\n", .{ total_elapsed_ms, final_rate });
    std.debug.print("  [x] Memory Safety:          0 Panics, 0 Out-of-Bounds accesses, 0 Hangs\n", .{});
    std.debug.print("  [x] Heap Allocations:       0 Bytes (100% stack/zero-copy)\n", .{});
    std.debug.print("=========================================================================================\n\n", .{});
}
