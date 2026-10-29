//! # Higher-Level ATT Protocol Clients
const std = @import("std");
const core_types = @import("../types.zig");
const UUID = core_types.UUID;
const att_types = @import("types.zig");
const pdu_mod = @import("pdu.zig");
const bearer_mod = @import("bearer.zig");

pub const AttOpcode = att_types.AttOpcode;
pub const AttErrorCode = att_types.AttErrorCode;
pub const AttError = att_types.AttError;
pub const AttPdu = pdu_mod.AttPdu;
pub const AttBearer = bearer_mod.AttBearer;

/// Client-side GATT Service Discovery state machine (`ReadByGroupType` -> `ReadByType` -> `FindInformation`).
pub const ServiceDiscoveryClient = struct {
    pub const Phase = enum {
        primary_services,
        characteristics,
        descriptors,
        complete,
    };

    phase: Phase = .primary_services,
    next_start_handle: u16 = 0x0001,
    range_end_handle: u16 = 0xFFFF,

    /// Generates the next ATT request PDU for the current discovery phase, or `null` when complete.
    pub fn nextRequest(self: *const ServiceDiscoveryClient) ?AttPdu {
        if (self.phase == .complete) return null;
        if (self.next_start_handle == 0 or self.next_start_handle > self.range_end_handle) return null;

        return switch (self.phase) {
            .primary_services => AttPdu{ .read_by_group_type_req = .{
                .start_handle = self.next_start_handle,
                .end_handle = self.range_end_handle,
                .group_uuid = UUID.from16(0x2800),
            } },
            .characteristics => AttPdu{ .read_by_type_req = .{
                .start_handle = self.next_start_handle,
                .end_handle = self.range_end_handle,
                .uuid = UUID.from16(0x2803),
            } },
            .descriptors => AttPdu{ .find_info_req = .{
                .start_handle = self.next_start_handle,
                .end_handle = self.range_end_handle,
            } },
            .complete => null,
        };
    }

    /// Advances the discovery cursor when a response or `AttributeNotFound` error is received.
    pub fn advanceOnEndHandle(self: *ServiceDiscoveryClient, last_handle: u16) void {
        if (last_handle == 0xFFFF or last_handle >= self.range_end_handle) {
            self.advancePhase();
        } else {
            self.next_start_handle = last_handle + 1;
        }
    }

    /// Transitions to the next discovery phase when `AttributeNotFound` (`0x0A`) is received.
    pub fn advancePhase(self: *ServiceDiscoveryClient) void {
        self.next_start_handle = 0x0001;
        self.range_end_handle = 0xFFFF;
        self.phase = switch (self.phase) {
            .primary_services => .characteristics,
            .characteristics => .descriptors,
            .descriptors, .complete => .complete,
        };
    }
};

/// Client-side Long Read helper (`ReadRequest` followed by `ReadBlobRequest` chunks).
pub const LongReadClient = struct {
    handle: u16,
    offset: u16 = 0,
    started: bool = false,
    done: bool = false,

    pub fn nextRequest(self: *LongReadClient) ?AttPdu {
        if (self.done) return null;
        if (!self.started) {
            self.started = true;
            return AttPdu{ .read_req = .{ .handle = self.handle } };
        }
        return AttPdu{ .read_blob_req = .{ .handle = self.handle, .offset = self.offset } };
    }

    pub fn onChunkReceived(self: *LongReadClient, chunk: []const u8, mtu: u16, dest: []u8) AttError!void {
        if (self.offset + chunk.len > dest.len) return AttError.BufferTooSmall;
        @memcpy(dest[self.offset .. self.offset + chunk.len], chunk);
        self.offset += @intCast(chunk.len);
        if (chunk.len < @as(usize, mtu - 1)) {
            self.done = true;
        }
    }
};

/// Client-side Queued Write helper (`PrepareWriteRequest` chunks followed by `ExecuteWriteRequest`).
pub const QueuedWriteClient = struct {
    handle: u16,
    payload: []const u8,
    offset: u16 = 0,
    executing: bool = false,
    done: bool = false,

    pub fn nextRequest(self: *QueuedWriteClient, mtu: u16) ?AttPdu {
        if (self.done) return null;
        const max_chunk = @as(usize, mtu) -| 5;
        if (self.offset < self.payload.len and max_chunk > 0) {
            const end = @min(self.payload.len, @as(usize, self.offset) + max_chunk);
            const part = self.payload[self.offset..end];
            const req = AttPdu{ .prepare_write_req = .{
                .handle = self.handle,
                .offset = self.offset,
                .part_value = part,
            } };
            self.offset = @intCast(end);
            return req;
        }
        if (!self.executing) {
            self.executing = true;
            return AttPdu{ .execute_write_req = .{ .flags = .commit } };
        }
        self.done = true;
        return null;
    }
};

