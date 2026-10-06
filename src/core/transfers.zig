//! # Zig-BLE Long Attribute Transfer Engine (ReadBlob & Prepare/Execute Write)
//!
//! Conforms to Bluetooth Core Specification (v5.4 / v6.0, Vol 3, Part F & G).
//! Provides high-level zero-allocation state machines for reading and writing
//! attributes that exceed the ATT MTU limit (> MTU - 3).

const std = @import("std");
const att = @import("att.zig");
const AttErrorCode = att.AttErrorCode;

pub const TransferError = error{
    BufferTooSmall,
    PayloadTooShort,
    InvalidOffset,
    QueueFull,
    PrepareMismatch,
    ExecuteFailed,
    Aborted,
};

/// Server-side queued prepare write chunk
pub const QueuedWriteChunk = struct {
    handle: u16,
    offset: u16,
    data: [256]u8 = undefined,
    data_len: u16 = 0,

    pub fn getData(self: *const QueuedWriteChunk) []const u8 {
        return self.data[0..self.data_len];
    }
};

/// Server-side Prepare Write Queue (fixed capacity, zero dynamic heap allocation)
pub const ServerPrepareWriteQueue = struct {
    const MAX_CHUNKS = 8;
    chunks: [MAX_CHUNKS]QueuedWriteChunk = undefined,
    count: usize = 0,

    pub fn init() ServerPrepareWriteQueue {
        return .{};
    }

    pub fn reset(self: *ServerPrepareWriteQueue) void {
        self.count = 0;
    }

    /// Enqueues a chunk from an incoming ATT_PREPARE_WRITE_REQ.
    pub fn enqueue(self: *ServerPrepareWriteQueue, req: att.PrepareWriteRequest) TransferError!void {
        if (self.count >= MAX_CHUNKS) return TransferError.QueueFull;
        if (req.part_value.len > 256) return TransferError.BufferTooSmall;

        var chunk = &self.chunks[self.count];
        chunk.handle = req.handle;
        chunk.offset = req.offset;
        @memcpy(chunk.data[0..req.part_value.len], req.part_value);
        chunk.data_len = @intCast(req.part_value.len);
        self.count += 1;
    }

    /// Assembles all queued prepare writes for a handle into a contiguous destination buffer.
    pub fn assembleForHandle(self: *const ServerPrepareWriteQueue, handle: u16, dest: []u8) TransferError!usize {
        var total_written: usize = 0;

        for (self.chunks[0..self.count]) |*c| {
            if (c.handle != handle) continue;
            const end = c.offset + c.data_len;
            if (end > dest.len) return TransferError.BufferTooSmall;
            @memcpy(dest[c.offset..end], c.getData());
            if (end > total_written) total_written = end;
        }

        return total_written;
    }
};

/// Client-side Long Write Chunker (slices long payload into ATT_PREPARE_WRITE_REQ chunks)
pub const LongWriteIterator = struct {
    handle: u16,
    data: []const u8,
    max_chunk_size: usize,
    offset: usize = 0,

    pub fn init(handle: u16, data: []const u8, mtu: u16) LongWriteIterator {
        // Prepare Write payload overhead is 5 bytes (1 byte opcode + 2 bytes handle + 2 bytes offset)
        const max_chunk = if (mtu > 5) mtu - 5 else 18;
        return .{
            .handle = handle,
            .data = data,
            .max_chunk_size = max_chunk,
            .offset = 0,
        };
    }

    pub fn next(self: *LongWriteIterator) ?att.PrepareWriteRequest {
        if (self.offset >= self.data.len) return null;

        const remaining = self.data.len - self.offset;
        const chunk_len = @min(remaining, self.max_chunk_size);
        const chunk = self.data[self.offset .. self.offset + chunk_len];

        const req = att.PrepareWriteRequest{
            .handle = self.handle,
            .offset = @intCast(self.offset),
            .part_value = chunk,
        };

        self.offset += chunk_len;
        return req;
    }

    pub fn isComplete(self: *const LongWriteIterator) bool {
        return self.offset >= self.data.len;
    }
};

/// Client-side Long Read Reassembler (iterates ReadBlobRequest until EOF)
pub const LongReadReassembler = struct {
    handle: u16,
    dest_buffer: []u8,
    max_chunk_size: usize,
    offset: usize = 0,
    is_done: bool = false,

    pub fn init(handle: u16, dest_buffer: []u8, mtu: u16) LongReadReassembler {
        // ReadBlob payload overhead is 1 byte (ATT_READ_BLOB_RSP opcode)
        const max_chunk = if (mtu > 1) mtu - 1 else 22;
        return .{
            .handle = handle,
            .dest_buffer = dest_buffer,
            .max_chunk_size = max_chunk,
            .offset = 0,
            .is_done = false,
        };
    }

    /// Generates the next ReadBlobRequest or null if complete.
    pub fn nextRequest(self: *const LongReadReassembler) ?att.ReadBlobRequest {
        if (self.is_done or self.offset >= self.dest_buffer.len) return null;
        return .{
            .handle = self.handle,
            .offset = @intCast(self.offset),
        };
    }

    /// Consumes a ReadBlobResponse chunk. Returns true when the entire long attribute is read.
    pub fn feedResponse(self: *LongReadReassembler, part_value: []const u8) TransferError!bool {
        if (self.is_done) return true;
        if (self.offset + part_value.len > self.dest_buffer.len) return TransferError.BufferTooSmall;

        @memcpy(self.dest_buffer[self.offset .. self.offset + part_value.len], part_value);
        self.offset += part_value.len;

        // An attribute read is complete if the returned length is less than MTU - 1
        if (part_value.len < self.max_chunk_size) {
            self.is_done = true;
            return true;
        }

        return false;
    }

    pub fn getAssembled(self: *const LongReadReassembler) []const u8 {
        return self.dest_buffer[0..self.offset];
    }
};

test "LongWriteIterator chunking test" {
    const handle: u16 = 0x002A;
    const test_payload = "This is a 64-byte long payload designed to test ATT Prepare Chunker!".*;
    var it = LongWriteIterator.init(handle, &test_payload, 23); // MTU 23 -> max chunk = 18 bytes

    var count: usize = 0;
    var total_bytes: usize = 0;
    while (it.next()) |chunk| {
        try std.testing.expectEqual(handle, chunk.handle);
        try std.testing.expect(chunk.part_value.len <= 18);
        total_bytes += chunk.part_value.len;
        count += 1;
    }

    try std.testing.expect(it.isComplete());
    try std.testing.expectEqual(test_payload.len, total_bytes);
    try std.testing.expect(count >= 4);
}

test "ServerPrepareWriteQueue enqueue and assemble test" {
    var queue = ServerPrepareWriteQueue.init();
    const handle: u16 = 0x0015;

    // Simulate 3 prepare write chunks
    const chunk1 = att.PrepareWriteRequest{ .handle = handle, .offset = 0, .part_value = "Hello, " };
    const chunk2 = att.PrepareWriteRequest{ .handle = handle, .offset = 7, .part_value = "World " };
    const chunk3 = att.PrepareWriteRequest{ .handle = handle, .offset = 13, .part_value = "from Zig BLE!" };

    try queue.enqueue(chunk1);
    try queue.enqueue(chunk2);
    try queue.enqueue(chunk3);

    var assembled: [64]u8 = undefined;
    const total_len = try queue.assembleForHandle(handle, &assembled);

    try std.testing.expectEqualStrings("Hello, World from Zig BLE!", assembled[0..total_len]);
}

test "LongReadReassembler multi-chunk reassembly test" {
    var dest: [128]u8 = undefined;
    var reader = LongReadReassembler.init(0x0030, &dest, 23); // MTU 23 -> max chunk = 22

    // First request at offset 0
    const req1 = reader.nextRequest().?;
    try std.testing.expectEqual(@as(u16, 0), req1.offset);

    // Feed chunk of full 22 bytes
    const chunk1 = "0123456789012345678901"; // 22 bytes
    const done1 = try reader.feedResponse(chunk1);
    try std.testing.expect(!done1);

    // Second request at offset 22
    const req2 = reader.nextRequest().?;
    try std.testing.expectEqual(@as(u16, 22), req2.offset);

    // Feed final chunk of 8 bytes (< 22, indicates EOF)
    const chunk2 = "ABCDEFGH";
    const done2 = try reader.feedResponse(chunk2);
    try std.testing.expect(done2);

    // Verify assembled string
    try std.testing.expectEqualStrings("0123456789012345678901ABCDEFGH", reader.getAssembled());
    try std.testing.expect(reader.nextRequest() == null);
}
