//! # Attribute Protocol (ATT) Protocol Data Units (PDUs)
const std = @import("std");
const core_types = @import("../types.zig");
const UUID = core_types.UUID;
const att_types = @import("types.zig");
pub const AttOpcode = att_types.AttOpcode;
pub const AttErrorCode = att_types.AttErrorCode;
pub const AttError = att_types.AttError;

/// ATT_ERROR_RSP (0x01): Signals an error encountered by an ATT request.
pub const ErrorResponse = struct {
    pub const opcode: AttOpcode = .error_rsp;

    request_opcode: u8,
    handle: u16,
    error_code: AttErrorCode,

    pub fn decode(bytes: []const u8) AttError!ErrorResponse {
        if (bytes.len < 5) return AttError.PayloadTooShort;
        if (bytes[0] != @intFromEnum(opcode)) return AttError.InvalidOpcode;
        return .{
            .request_opcode = bytes[1],
            .handle = std.mem.readInt(u16, bytes[2..4], .little),
            .error_code = @enumFromInt(bytes[4]),
        };
    }

    pub fn encode(self: ErrorResponse, dest: []u8) AttError!usize {
        if (dest.len < 5) return AttError.BufferTooSmall;
        dest[0] = @intFromEnum(opcode);
        dest[1] = self.request_opcode;
        std.mem.writeInt(u16, dest[2..4], self.handle, .little);
        dest[4] = @intFromEnum(self.error_code);
        return 5;
    }
};

/// ATT_EXCHANGE_MTU_REQ (0x02): Client initiates MTU negotiation.
pub const ExchangeMtuRequest = struct {
    pub const opcode: AttOpcode = .exchange_mtu_req;

    client_rx_mtu: u16,

    pub fn decode(bytes: []const u8) AttError!ExchangeMtuRequest {
        if (bytes.len < 3) return AttError.PayloadTooShort;
        if (bytes[0] != @intFromEnum(opcode)) return AttError.InvalidOpcode;
        return .{ .client_rx_mtu = std.mem.readInt(u16, bytes[1..3], .little) };
    }

    pub fn encode(self: ExchangeMtuRequest, dest: []u8) AttError!usize {
        if (dest.len < 3) return AttError.BufferTooSmall;
        dest[0] = @intFromEnum(opcode);
        std.mem.writeInt(u16, dest[1..3], self.client_rx_mtu, .little);
        return 3;
    }
};

/// ATT_EXCHANGE_MTU_RSP (0x03): Server responds with its maximum RX MTU.
pub const ExchangeMtuResponse = struct {
    pub const opcode: AttOpcode = .exchange_mtu_rsp;

    server_rx_mtu: u16,

    pub fn decode(bytes: []const u8) AttError!ExchangeMtuResponse {
        if (bytes.len < 3) return AttError.PayloadTooShort;
        if (bytes[0] != @intFromEnum(opcode)) return AttError.InvalidOpcode;
        return .{ .server_rx_mtu = std.mem.readInt(u16, bytes[1..3], .little) };
    }

    pub fn encode(self: ExchangeMtuResponse, dest: []u8) AttError!usize {
        if (dest.len < 3) return AttError.BufferTooSmall;
        dest[0] = @intFromEnum(opcode);
        std.mem.writeInt(u16, dest[1..3], self.server_rx_mtu, .little);
        return 3;
    }
};

/// ATT_FIND_INFO_REQ (0x04): Obtains mapping of handle to UUID.
pub const FindInformationRequest = struct {
    pub const opcode: AttOpcode = .find_info_req;

    start_handle: u16,
    end_handle: u16,

    pub fn decode(bytes: []const u8) AttError!FindInformationRequest {
        if (bytes.len < 5) return AttError.PayloadTooShort;
        if (bytes[0] != @intFromEnum(opcode)) return AttError.InvalidOpcode;
        return .{
            .start_handle = std.mem.readInt(u16, bytes[1..3], .little),
            .end_handle = std.mem.readInt(u16, bytes[3..5], .little),
        };
    }

    pub fn encode(self: FindInformationRequest, dest: []u8) AttError!usize {
        if (dest.len < 5) return AttError.BufferTooSmall;
        dest[0] = @intFromEnum(opcode);
        std.mem.writeInt(u16, dest[1..3], self.start_handle, .little);
        std.mem.writeInt(u16, dest[3..5], self.end_handle, .little);
        return 5;
    }
};

/// ATT_FIND_INFO_RSP (0x05): List of handle-to-UUID mappings.
pub const FindInformationResponse = struct {
    pub const opcode: AttOpcode = .find_info_rsp;

    pub const Format = enum(u8) {
        uuid16 = 0x01,
        uuid128 = 0x02,
        _,
    };

    pub const Item = struct {
        handle: u16,
        uuid: UUID,
    };

    pub const Iterator = struct {
        format: Format,
        data: []const u8,
        offset: usize = 0,

        pub fn next(self: *Iterator) ?Item {
            switch (self.format) {
                .uuid16 => {
                    if (self.offset + 4 > self.data.len) return null;
                    const handle = std.mem.readInt(u16, self.data[self.offset..][0..2], .little);
                    const uuid16 = std.mem.readInt(u16, self.data[self.offset + 2 ..][0..2], .little);
                    self.offset += 4;
                    return Item{ .handle = handle, .uuid = UUID.from16(uuid16) };
                },
                .uuid128 => {
                    if (self.offset + 18 > self.data.len) return null;
                    const handle = std.mem.readInt(u16, self.data[self.offset..][0..2], .little);
                    var u_bytes: [16]u8 = undefined;
                    @memcpy(&u_bytes, self.data[self.offset + 2 .. self.offset + 18]);
                    self.offset += 18;
                    return Item{ .handle = handle, .uuid = UUID{ .bytes = u_bytes } };
                },
                _ => return null,
            }
        }
    };

    format: Format,
    data: []const u8,

    pub fn decode(bytes: []const u8) AttError!FindInformationResponse {
        if (bytes.len < 2) return AttError.PayloadTooShort;
        if (bytes[0] != @intFromEnum(opcode)) return AttError.InvalidOpcode;
        return .{
            .format = @enumFromInt(bytes[1]),
            .data = bytes[2..],
        };
    }

    pub fn iterator(self: FindInformationResponse) Iterator {
        return .{
            .format = self.format,
            .data = self.data,
        };
    }
};

/// ATT_FIND_BY_TYPE_VALUE_REQ (0x06): Searches for attributes with a given type and value.
pub const FindByTypeValueRequest = struct {
    pub const opcode: AttOpcode = .find_by_type_val_req;

    start_handle: u16,
    end_handle: u16,
    att_type: u16,
    att_value: []const u8,

    pub fn decode(bytes: []const u8) AttError!FindByTypeValueRequest {
        if (bytes.len < 7) return AttError.PayloadTooShort;
        if (bytes[0] != @intFromEnum(opcode)) return AttError.InvalidOpcode;
        return .{
            .start_handle = std.mem.readInt(u16, bytes[1..3], .little),
            .end_handle = std.mem.readInt(u16, bytes[3..5], .little),
            .att_type = std.mem.readInt(u16, bytes[5..7], .little),
            .att_value = bytes[7..],
        };
    }

    pub fn encode(self: FindByTypeValueRequest, dest: []u8) AttError!usize {
        const total = 7 + self.att_value.len;
        if (dest.len < total) return AttError.BufferTooSmall;
        dest[0] = @intFromEnum(opcode);
        std.mem.writeInt(u16, dest[1..3], self.start_handle, .little);
        std.mem.writeInt(u16, dest[3..5], self.end_handle, .little);
        std.mem.writeInt(u16, dest[5..7], self.att_type, .little);
        @memcpy(dest[7..total], self.att_value);
        return total;
    }
};

/// ATT_FIND_BY_TYPE_VALUE_RSP (0x07): Returns found handles and group end handles.
pub const FindByTypeValueResponse = struct {
    pub const opcode: AttOpcode = .find_by_type_val_rsp;

    pub const Element = struct {
        found_handle: u16,
        group_end_handle: u16,
    };

    pub const Iterator = struct {
        data: []const u8,
        offset: usize = 0,

        pub fn next(self: *Iterator) ?Element {
            if (self.offset + 4 > self.data.len) return null;
            const found = std.mem.readInt(u16, self.data[self.offset..][0..2], .little);
            const end = std.mem.readInt(u16, self.data[self.offset + 2 ..][0..2], .little);
            self.offset += 4;
            return Element{ .found_handle = found, .group_end_handle = end };
        }
    };

    data: []const u8,

    pub fn decode(bytes: []const u8) AttError!FindByTypeValueResponse {
        if (bytes.len < 1) return AttError.PayloadTooShort;
        if (bytes[0] != @intFromEnum(opcode)) return AttError.InvalidOpcode;
        return .{ .data = bytes[1..] };
    }

    pub fn iterator(self: FindByTypeValueResponse) Iterator {
        return .{ .data = self.data };
    }
};

/// ATT_READ_BY_TYPE_REQ (0x08): Reads attribute values matching a specified 16-bit or 128-bit UUID.
pub const ReadByTypeRequest = struct {
    pub const opcode: AttOpcode = .read_by_type_req;

    start_handle: u16,
    end_handle: u16,
    uuid: UUID,

    pub fn decode(bytes: []const u8) AttError!ReadByTypeRequest {
        if (bytes.len < 7) return AttError.PayloadTooShort;
        if (bytes[0] != @intFromEnum(opcode)) return AttError.InvalidOpcode;
        const start = std.mem.readInt(u16, bytes[1..3], .little);
        const end = std.mem.readInt(u16, bytes[3..5], .little);
        const uuid = if (bytes.len == 7)
            UUID.from16(std.mem.readInt(u16, bytes[5..7], .little))
        else if (bytes.len >= 21)
            UUID{ .bytes = bytes[5..21].* }
        else
            return AttError.MalformedUuid;

        return .{
            .start_handle = start,
            .end_handle = end,
            .uuid = uuid,
        };
    }

    pub fn encode(self: ReadByTypeRequest, dest: []u8) AttError!usize {
        if (self.uuid.to16()) |u16_val| {
            if (dest.len < 7) return AttError.BufferTooSmall;
            dest[0] = @intFromEnum(opcode);
            std.mem.writeInt(u16, dest[1..3], self.start_handle, .little);
            std.mem.writeInt(u16, dest[3..5], self.end_handle, .little);
            std.mem.writeInt(u16, dest[5..7], u16_val, .little);
            return 7;
        } else {
            if (dest.len < 21) return AttError.BufferTooSmall;
            dest[0] = @intFromEnum(opcode);
            std.mem.writeInt(u16, dest[1..3], self.start_handle, .little);
            std.mem.writeInt(u16, dest[3..5], self.end_handle, .little);
            @memcpy(dest[5..21], &self.uuid.bytes);
            return 21;
        }
    }
};

/// ATT_READ_BY_TYPE_RSP (0x09): List of handle-value pairs.
pub const ReadByTypeResponse = struct {
    pub const opcode: AttOpcode = .read_by_type_rsp;

    pub const Element = struct {
        handle: u16,
        value: []const u8,
    };

    pub const Iterator = struct {
        length: usize,
        data: []const u8,
        offset: usize = 0,

        pub fn next(self: *Iterator) ?Element {
            if (self.length < 2) return null;
            if (self.offset + self.length > self.data.len) return null;
            const item_bytes = self.data[self.offset .. self.offset + self.length];
            const handle = std.mem.readInt(u16, item_bytes[0..2], .little);
            const value = item_bytes[2..];
            self.offset += self.length;
            return Element{ .handle = handle, .value = value };
        }
    };

    length: u8,
    data: []const u8,

    pub fn decode(bytes: []const u8) AttError!ReadByTypeResponse {
        if (bytes.len < 2) return AttError.PayloadTooShort;
        if (bytes[0] != @intFromEnum(opcode)) return AttError.InvalidOpcode;
        return .{
            .length = bytes[1],
            .data = bytes[2..],
        };
    }

    pub fn iterator(self: ReadByTypeResponse) Iterator {
        return .{
            .length = self.length,
            .data = self.data,
        };
    }
};

/// ATT_READ_REQ (0x0A): Reads an attribute value by its 16-bit handle.
pub const ReadRequest = struct {
    pub const opcode: AttOpcode = .read_req;

    handle: u16,

    pub fn decode(bytes: []const u8) AttError!ReadRequest {
        if (bytes.len < 3) return AttError.PayloadTooShort;
        if (bytes[0] != @intFromEnum(opcode)) return AttError.InvalidOpcode;
        return .{ .handle = std.mem.readInt(u16, bytes[1..3], .little) };
    }

    pub fn encode(self: ReadRequest, dest: []u8) AttError!usize {
        if (dest.len < 3) return AttError.BufferTooSmall;
        dest[0] = @intFromEnum(opcode);
        std.mem.writeInt(u16, dest[1..3], self.handle, .little);
        return 3;
    }
};

/// ATT_READ_RSP (0x0B): Response containing the attribute value.
pub const ReadResponse = struct {
    pub const opcode: AttOpcode = .read_rsp;

    value: []const u8,

    pub fn decode(bytes: []const u8) AttError!ReadResponse {
        if (bytes.len < 1) return AttError.PayloadTooShort;
        if (bytes[0] != @intFromEnum(opcode)) return AttError.InvalidOpcode;
        return .{ .value = bytes[1..] };
    }

    pub fn encode(self: ReadResponse, dest: []u8) AttError!usize {
        const total = 1 + self.value.len;
        if (dest.len < total) return AttError.BufferTooSmall;
        dest[0] = @intFromEnum(opcode);
        @memcpy(dest[1..total], self.value);
        return total;
    }
};

/// ATT_READ_BLOB_REQ (0x0C): Reads a part of an attribute value starting at an offset.
pub const ReadBlobRequest = struct {
    pub const opcode: AttOpcode = .read_blob_req;

    handle: u16,
    offset: u16,

    pub fn decode(bytes: []const u8) AttError!ReadBlobRequest {
        if (bytes.len < 5) return AttError.PayloadTooShort;
        if (bytes[0] != @intFromEnum(opcode)) return AttError.InvalidOpcode;
        return .{
            .handle = std.mem.readInt(u16, bytes[1..3], .little),
            .offset = std.mem.readInt(u16, bytes[3..5], .little),
        };
    }

    pub fn encode(self: ReadBlobRequest, dest: []u8) AttError!usize {
        if (dest.len < 5) return AttError.BufferTooSmall;
        dest[0] = @intFromEnum(opcode);
        std.mem.writeInt(u16, dest[1..3], self.handle, .little);
        std.mem.writeInt(u16, dest[3..5], self.offset, .little);
        return 5;
    }
};

/// ATT_READ_BLOB_RSP (0x0D): Returns the requested chunk of a long attribute value.
pub const ReadBlobResponse = struct {
    pub const opcode: AttOpcode = .read_blob_rsp;

    part_value: []const u8,

    pub fn decode(bytes: []const u8) AttError!ReadBlobResponse {
        if (bytes.len < 1) return AttError.PayloadTooShort;
        if (bytes[0] != @intFromEnum(opcode)) return AttError.InvalidOpcode;
        return .{ .part_value = bytes[1..] };
    }

    pub fn encode(self: ReadBlobResponse, dest: []u8) AttError!usize {
        const total = 1 + self.part_value.len;
        if (dest.len < total) return AttError.BufferTooSmall;
        dest[0] = @intFromEnum(opcode);
        @memcpy(dest[1..total], self.part_value);
        return total;
    }
};

/// ATT_READ_BY_GROUP_TYPE_REQ (0x10): Used primarily for GATT Service Discovery.
pub const ReadByGroupTypeRequest = struct {
    pub const opcode: AttOpcode = .read_by_group_type_req;

    start_handle: u16,
    end_handle: u16,
    group_uuid: UUID,

    pub fn decode(bytes: []const u8) AttError!ReadByGroupTypeRequest {
        if (bytes.len < 7) return AttError.PayloadTooShort;
        if (bytes[0] != @intFromEnum(opcode)) return AttError.InvalidOpcode;
        const start = std.mem.readInt(u16, bytes[1..3], .little);
        const end = std.mem.readInt(u16, bytes[3..5], .little);
        const uuid = if (bytes.len == 7)
            UUID.from16(std.mem.readInt(u16, bytes[5..7], .little))
        else if (bytes.len >= 21)
            UUID{ .bytes = bytes[5..21].* }
        else
            return AttError.MalformedUuid;

        return .{
            .start_handle = start,
            .end_handle = end,
            .group_uuid = uuid,
        };
    }

    pub fn encode(self: ReadByGroupTypeRequest, dest: []u8) AttError!usize {
        if (self.group_uuid.to16()) |u16_val| {
            if (dest.len < 7) return AttError.BufferTooSmall;
            dest[0] = @intFromEnum(opcode);
            std.mem.writeInt(u16, dest[1..3], self.start_handle, .little);
            std.mem.writeInt(u16, dest[3..5], self.end_handle, .little);
            std.mem.writeInt(u16, dest[5..7], u16_val, .little);
            return 7;
        } else {
            if (dest.len < 21) return AttError.BufferTooSmall;
            dest[0] = @intFromEnum(opcode);
            std.mem.writeInt(u16, dest[1..3], self.start_handle, .little);
            std.mem.writeInt(u16, dest[3..5], self.end_handle, .little);
            @memcpy(dest[5..21], &self.group_uuid.bytes);
            return 21;
        }
    }
};

/// ATT_READ_BY_GROUP_TYPE_RSP (0x11): Group range and Service UUID list.
pub const ReadByGroupTypeResponse = struct {
    pub const opcode: AttOpcode = .read_by_group_type_rsp;

    pub const Element = struct {
        start_handle: u16,
        end_handle: u16,
        uuid: UUID,
    };

    pub const Iterator = struct {
        length: usize,
        data: []const u8,
        offset: usize = 0,

        pub fn next(self: *Iterator) ?Element {
            if (self.length < 4) return null;
            if (self.offset + self.length > self.data.len) return null;
            const item = self.data[self.offset .. self.offset + self.length];
            const start = std.mem.readInt(u16, item[0..2], .little);
            const end = std.mem.readInt(u16, item[2..4], .little);
            const uuid_bytes = item[4..];
            const uuid: UUID = if (uuid_bytes.len == 2)
                UUID.from16(std.mem.readInt(u16, uuid_bytes[0..2], .little))
            else if (uuid_bytes.len == 16)
                UUID{ .bytes = uuid_bytes[0..16].* }
            else
                return null;

            self.offset += self.length;
            return Element{
                .start_handle = start,
                .end_handle = end,
                .uuid = uuid,
            };
        }
    };

    length: u8,
    data: []const u8,

    pub fn decode(bytes: []const u8) AttError!ReadByGroupTypeResponse {
        if (bytes.len < 2) return AttError.PayloadTooShort;
        if (bytes[0] != @intFromEnum(opcode)) return AttError.InvalidOpcode;
        return .{
            .length = bytes[1],
            .data = bytes[2..],
        };
    }

    pub fn iterator(self: ReadByGroupTypeResponse) Iterator {
        return .{
            .length = self.length,
            .data = self.data,
        };
    }
};

/// ATT_WRITE_REQ (0x12): Write an attribute value with acknowledgment.
pub const WriteRequest = struct {
    pub const opcode: AttOpcode = .write_req;

    handle: u16,
    value: []const u8,

    pub fn decode(bytes: []const u8) AttError!WriteRequest {
        if (bytes.len < 3) return AttError.PayloadTooShort;
        if (bytes[0] != @intFromEnum(opcode)) return AttError.InvalidOpcode;
        return .{
            .handle = std.mem.readInt(u16, bytes[1..3], .little),
            .value = bytes[3..],
        };
    }

    pub fn encode(self: WriteRequest, dest: []u8) AttError!usize {
        const total = 3 + self.value.len;
        if (dest.len < total) return AttError.BufferTooSmall;
        dest[0] = @intFromEnum(opcode);
        std.mem.writeInt(u16, dest[1..3], self.handle, .little);
        @memcpy(dest[3..total], self.value);
        return total;
    }
};

/// ATT_WRITE_RSP (0x13): Write response acknowledgement.
pub const WriteResponse = struct {
    pub const opcode: AttOpcode = .write_rsp;

    pub fn decode(bytes: []const u8) AttError!WriteResponse {
        if (bytes.len < 1) return AttError.PayloadTooShort;
        if (bytes[0] != @intFromEnum(opcode)) return AttError.InvalidOpcode;
        return .{};
    }

    pub fn encode(dest: []u8) AttError!usize {
        if (dest.len < 1) return AttError.BufferTooSmall;
        dest[0] = @intFromEnum(opcode);
        return 1;
    }
};

/// ATT_WRITE_CMD (0x52): Fast unacknowledged write command.
pub const WriteCommand = struct {
    pub const opcode: AttOpcode = .write_cmd;

    handle: u16,
    value: []const u8,

    pub fn decode(bytes: []const u8) AttError!WriteCommand {
        if (bytes.len < 3) return AttError.PayloadTooShort;
        if (bytes[0] != @intFromEnum(opcode)) return AttError.InvalidOpcode;
        return .{
            .handle = std.mem.readInt(u16, bytes[1..3], .little),
            .value = bytes[3..],
        };
    }

    pub fn encode(self: WriteCommand, dest: []u8) AttError!usize {
        const total = 3 + self.value.len;
        if (dest.len < total) return AttError.BufferTooSmall;
        dest[0] = @intFromEnum(opcode);
        std.mem.writeInt(u16, dest[1..3], self.handle, .little);
        @memcpy(dest[3..total], self.value);
        return total;
    }
};

/// ATT_PREPARE_WRITE_REQ (0x16): Buffers a part of a long write on the server.
pub const PrepareWriteRequest = struct {
    pub const opcode: AttOpcode = .prepare_write_req;

    handle: u16,
    offset: u16,
    part_value: []const u8,

    pub fn decode(bytes: []const u8) AttError!PrepareWriteRequest {
        if (bytes.len < 5) return AttError.PayloadTooShort;
        if (bytes[0] != @intFromEnum(opcode)) return AttError.InvalidOpcode;
        return .{
            .handle = std.mem.readInt(u16, bytes[1..3], .little),
            .offset = std.mem.readInt(u16, bytes[3..5], .little),
            .part_value = bytes[5..],
        };
    }

    pub fn encode(self: PrepareWriteRequest, dest: []u8) AttError!usize {
        const total = 5 + self.part_value.len;
        if (dest.len < total) return AttError.BufferTooSmall;
        dest[0] = @intFromEnum(opcode);
        std.mem.writeInt(u16, dest[1..3], self.handle, .little);
        std.mem.writeInt(u16, dest[3..5], self.offset, .little);
        @memcpy(dest[5..total], self.part_value);
        return total;
    }
};

/// ATT_EXECUTE_WRITE_REQ (0x18): Commits or cancels all pending prepared writes.
pub const ExecuteWriteRequest = struct {
    pub const opcode: AttOpcode = .execute_write_req;

    pub const Flags = enum(u8) {
        cancel = 0x00,
        commit = 0x01,
        _,
    };

    flags: Flags,

    pub fn decode(bytes: []const u8) AttError!ExecuteWriteRequest {
        if (bytes.len < 2) return AttError.PayloadTooShort;
        if (bytes[0] != @intFromEnum(opcode)) return AttError.InvalidOpcode;
        return .{ .flags = @enumFromInt(bytes[1]) };
    }

    pub fn encode(self: ExecuteWriteRequest, dest: []u8) AttError!usize {
        if (dest.len < 2) return AttError.BufferTooSmall;
        dest[0] = @intFromEnum(opcode);
        dest[1] = @intFromEnum(self.flags);
        return 2;
    }
};

/// ATT_PREPARE_WRITE_RSP (0x17): Acknowledges prepare write request.
pub const PrepareWriteResponse = struct {
    pub const opcode: AttOpcode = .prepare_write_rsp;

    handle: u16,
    offset: u16,
    part_value: []const u8,

    pub fn decode(bytes: []const u8) AttError!PrepareWriteResponse {
        if (bytes.len < 5) return AttError.PayloadTooShort;
        if (bytes[0] != @intFromEnum(opcode)) return AttError.InvalidOpcode;
        return .{
            .handle = std.mem.readInt(u16, bytes[1..3], .little),
            .offset = std.mem.readInt(u16, bytes[3..5], .little),
            .part_value = bytes[5..],
        };
    }

    pub fn encode(self: PrepareWriteResponse, dest: []u8) AttError!usize {
        const total = 5 + self.part_value.len;
        if (dest.len < total) return AttError.BufferTooSmall;
        dest[0] = @intFromEnum(opcode);
        std.mem.writeInt(u16, dest[1..3], self.handle, .little);
        std.mem.writeInt(u16, dest[3..5], self.offset, .little);
        @memcpy(dest[5..total], self.part_value);
        return total;
    }
};

/// ATT_EXECUTE_WRITE_RSP (0x19): Confirms execution or cancellation of prepared writes.
pub const ExecuteWriteResponse = struct {
    pub const opcode: AttOpcode = .execute_write_rsp;

    pub fn decode(bytes: []const u8) AttError!ExecuteWriteResponse {
        if (bytes.len < 1) return AttError.PayloadTooShort;
        if (bytes[0] != @intFromEnum(opcode)) return AttError.InvalidOpcode;
        return .{};
    }

    pub fn encode(dest: []u8) AttError!usize {
        if (dest.len < 1) return AttError.BufferTooSmall;
        dest[0] = @intFromEnum(opcode);
        return 1;
    }
};

/// ATT_READ_MULTIPLE_REQ (0x0E): Reads multiple attribute values by handles.
pub const ReadMultipleRequest = struct {
    pub const opcode: AttOpcode = .read_multiple_req;

    handles_data: []const u8,

    pub fn decode(bytes: []const u8) AttError!ReadMultipleRequest {
        if (bytes.len < 5) return AttError.PayloadTooShort;
        if (bytes[0] != @intFromEnum(opcode)) return AttError.InvalidOpcode;
        if ((bytes.len - 1) % 2 != 0) return AttError.InvalidLength;
        return .{ .handles_data = bytes[1..] };
    }

    pub fn encode(handles: []const u16, dest: []u8) AttError!usize {
        const total = 1 + handles.len * 2;
        if (dest.len < total) return AttError.BufferTooSmall;
        dest[0] = @intFromEnum(opcode);
        var off: usize = 1;
        for (handles) |h| {
            std.mem.writeInt(u16, dest[off .. off + 2], h, .little);
            off += 2;
        }
        return total;
    }
};

/// ATT_READ_MULTIPLE_RSP (0x0F): Concatenated attribute values.
pub const ReadMultipleResponse = struct {
    pub const opcode: AttOpcode = .read_multiple_rsp;

    values: []const u8,

    pub fn decode(bytes: []const u8) AttError!ReadMultipleResponse {
        if (bytes.len < 1) return AttError.PayloadTooShort;
        if (bytes[0] != @intFromEnum(opcode)) return AttError.InvalidOpcode;
        return .{ .values = bytes[1..] };
    }

    pub fn encode(self: ReadMultipleResponse, dest: []u8) AttError!usize {
        const total = 1 + self.values.len;
        if (dest.len < total) return AttError.BufferTooSmall;
        dest[0] = @intFromEnum(opcode);
        @memcpy(dest[1..total], self.values);
        return total;
    }
};

/// ATT_SIGNED_WRITE_CMD (0xD2): Authenticated write with 12-byte MAC signature.
pub const SignedWriteCommand = struct {
    pub const opcode: AttOpcode = .signed_write_cmd;

    handle: u16,
    value: []const u8,
    signature: [12]u8,

    pub fn decode(bytes: []const u8) AttError!SignedWriteCommand {
        if (bytes.len < 15) return AttError.PayloadTooShort;
        if (bytes[0] != @intFromEnum(opcode)) return AttError.InvalidOpcode;
        const handle = std.mem.readInt(u16, bytes[1..3], .little);
        const sig_offset = bytes.len - 12;
        var sig: [12]u8 = undefined;
        @memcpy(&sig, bytes[sig_offset..]);
        return .{
            .handle = handle,
            .value = bytes[3..sig_offset],
            .signature = sig,
        };
    }

    pub fn encode(self: SignedWriteCommand, dest: []u8) AttError!usize {
        const total = 15 + self.value.len;
        if (dest.len < total) return AttError.BufferTooSmall;
        dest[0] = @intFromEnum(opcode);
        std.mem.writeInt(u16, dest[1..3], self.handle, .little);
        const val_end = 3 + self.value.len;
        @memcpy(dest[3..val_end], self.value);
        @memcpy(dest[val_end..total], &self.signature);
        return total;
    }
};

/// ATT_HANDLE_VALUE_NTF (0x1B): Server sends an unacknowledged value notification.
pub const HandleValueNotification = struct {
    pub const opcode: AttOpcode = .handle_value_ntf;

    handle: u16,
    value: []const u8,

    pub fn decode(bytes: []const u8) AttError!HandleValueNotification {
        if (bytes.len < 3) return AttError.PayloadTooShort;
        if (bytes[0] != @intFromEnum(opcode)) return AttError.InvalidOpcode;
        return .{
            .handle = std.mem.readInt(u16, bytes[1..3], .little),
            .value = bytes[3..],
        };
    }

    pub fn encode(self: HandleValueNotification, dest: []u8) AttError!usize {
        const total = 3 + self.value.len;
        if (dest.len < total) return AttError.BufferTooSmall;
        dest[0] = @intFromEnum(opcode);
        std.mem.writeInt(u16, dest[1..3], self.handle, .little);
        @memcpy(dest[3..total], self.value);
        return total;
    }
};

/// ATT_HANDLE_VALUE_IND (0x1D): Server sends an acknowledged value indication.
pub const HandleValueIndication = struct {
    pub const opcode: AttOpcode = .handle_value_ind;

    handle: u16,
    value: []const u8,

    pub fn decode(bytes: []const u8) AttError!HandleValueIndication {
        if (bytes.len < 3) return AttError.PayloadTooShort;
        if (bytes[0] != @intFromEnum(opcode)) return AttError.InvalidOpcode;
        return .{
            .handle = std.mem.readInt(u16, bytes[1..3], .little),
            .value = bytes[3..],
        };
    }

    pub fn encode(self: HandleValueIndication, dest: []u8) AttError!usize {
        const total = 3 + self.value.len;
        if (dest.len < total) return AttError.BufferTooSmall;
        dest[0] = @intFromEnum(opcode);
        std.mem.writeInt(u16, dest[1..3], self.handle, .little);
        @memcpy(dest[3..total], self.value);
        return total;
    }
};

/// ATT_HANDLE_VALUE_CFM (0x1E): Client confirms receipt of an indication.
pub const HandleValueConfirmation = struct {
    pub const opcode: AttOpcode = .handle_value_cfm;

    pub fn decode(bytes: []const u8) AttError!HandleValueConfirmation {
        if (bytes.len < 1) return AttError.PayloadTooShort;
        if (bytes[0] != @intFromEnum(opcode)) return AttError.InvalidOpcode;
        return .{};
    }

    pub fn encode(dest: []u8) AttError!usize {
        if (dest.len < 1) return AttError.BufferTooSmall;
        dest[0] = @intFromEnum(opcode);
        return 1;
    }
};

// ============================================================================
// Top-Level Tagged Union
// ============================================================================

/// Polymorphic ATT Protocol Data Unit (PDU) representing any valid ATT packet.
pub const AttPdu = union(enum) {
    error_rsp: ErrorResponse,
    exchange_mtu_req: ExchangeMtuRequest,
    exchange_mtu_rsp: ExchangeMtuResponse,
    find_info_req: FindInformationRequest,
    find_info_rsp: FindInformationResponse,
    find_by_type_val_req: FindByTypeValueRequest,
    find_by_type_val_rsp: FindByTypeValueResponse,
    read_by_type_req: ReadByTypeRequest,
    read_by_type_rsp: ReadByTypeResponse,
    read_req: ReadRequest,
    read_rsp: ReadResponse,
    read_blob_req: ReadBlobRequest,
    read_blob_rsp: ReadBlobResponse,
    read_multiple_req: ReadMultipleRequest,
    read_multiple_rsp: ReadMultipleResponse,
    read_by_group_type_req: ReadByGroupTypeRequest,
    read_by_group_type_rsp: ReadByGroupTypeResponse,
    write_req: WriteRequest,
    write_rsp: WriteResponse,
    write_cmd: WriteCommand,
    signed_write_cmd: SignedWriteCommand,
    prepare_write_req: PrepareWriteRequest,
    prepare_write_rsp: PrepareWriteResponse,
    execute_write_req: ExecuteWriteRequest,
    execute_write_rsp: ExecuteWriteResponse,
    handle_value_ntf: HandleValueNotification,
    handle_value_ind: HandleValueIndication,
    handle_value_cfm: HandleValueConfirmation,

    /// Decodes a raw ATT frame into its concrete typed representation.
    /// Performs 100% zero dynamic heap allocations.
    pub fn parse(raw_packet: []const u8) AttError!AttPdu {
        if (raw_packet.len == 0) return AttError.PayloadTooShort;
        const op: AttOpcode = @enumFromInt(raw_packet[0]);
        return switch (op) {
            .error_rsp => AttPdu{ .error_rsp = try ErrorResponse.decode(raw_packet) },
            .exchange_mtu_req => AttPdu{ .exchange_mtu_req = try ExchangeMtuRequest.decode(raw_packet) },
            .exchange_mtu_rsp => AttPdu{ .exchange_mtu_rsp = try ExchangeMtuResponse.decode(raw_packet) },
            .find_info_req => AttPdu{ .find_info_req = try FindInformationRequest.decode(raw_packet) },
            .find_info_rsp => AttPdu{ .find_info_rsp = try FindInformationResponse.decode(raw_packet) },
            .find_by_type_val_req => AttPdu{ .find_by_type_val_req = try FindByTypeValueRequest.decode(raw_packet) },
            .find_by_type_val_rsp => AttPdu{ .find_by_type_val_rsp = try FindByTypeValueResponse.decode(raw_packet) },
            .read_by_type_req => AttPdu{ .read_by_type_req = try ReadByTypeRequest.decode(raw_packet) },
            .read_by_type_rsp => AttPdu{ .read_by_type_rsp = try ReadByTypeResponse.decode(raw_packet) },
            .read_req => AttPdu{ .read_req = try ReadRequest.decode(raw_packet) },
            .read_rsp => AttPdu{ .read_rsp = try ReadResponse.decode(raw_packet) },
            .read_blob_req => AttPdu{ .read_blob_req = try ReadBlobRequest.decode(raw_packet) },
            .read_blob_rsp => AttPdu{ .read_blob_rsp = try ReadBlobResponse.decode(raw_packet) },
            .read_multiple_req => AttPdu{ .read_multiple_req = try ReadMultipleRequest.decode(raw_packet) },
            .read_multiple_rsp => AttPdu{ .read_multiple_rsp = try ReadMultipleResponse.decode(raw_packet) },
            .read_by_group_type_req => AttPdu{ .read_by_group_type_req = try ReadByGroupTypeRequest.decode(raw_packet) },
            .read_by_group_type_rsp => AttPdu{ .read_by_group_type_rsp = try ReadByGroupTypeResponse.decode(raw_packet) },
            .write_req => AttPdu{ .write_req = try WriteRequest.decode(raw_packet) },
            .write_rsp => AttPdu{ .write_rsp = try WriteResponse.decode(raw_packet) },
            .write_cmd => AttPdu{ .write_cmd = try WriteCommand.decode(raw_packet) },
            .signed_write_cmd => AttPdu{ .signed_write_cmd = try SignedWriteCommand.decode(raw_packet) },
            .prepare_write_req => AttPdu{ .prepare_write_req = try PrepareWriteRequest.decode(raw_packet) },
            .prepare_write_rsp => AttPdu{ .prepare_write_rsp = try PrepareWriteResponse.decode(raw_packet) },
            .execute_write_req => AttPdu{ .execute_write_req = try ExecuteWriteRequest.decode(raw_packet) },
            .execute_write_rsp => AttPdu{ .execute_write_rsp = try ExecuteWriteResponse.decode(raw_packet) },
            .handle_value_ntf => AttPdu{ .handle_value_ntf = try HandleValueNotification.decode(raw_packet) },
            .handle_value_ind => AttPdu{ .handle_value_ind = try HandleValueIndication.decode(raw_packet) },
            .handle_value_cfm => AttPdu{ .handle_value_cfm = try HandleValueConfirmation.decode(raw_packet) },
            _ => AttError.InvalidOpcode,
        };
    }

    /// Serializes the PDU into raw ATT wire bytes.
    pub fn serialize(self: AttPdu, dest: []u8) AttError!usize {
        return switch (self) {
            .error_rsp => |p| p.encode(dest),
            .exchange_mtu_req => |p| p.encode(dest),
            .exchange_mtu_rsp => |p| p.encode(dest),
            .find_info_req => |p| p.encode(dest),
            .find_info_rsp => AttError.InvalidOpcode, // Requires format-specific encoding
            .find_by_type_val_req => |p| p.encode(dest),
            .find_by_type_val_rsp => AttError.InvalidOpcode,
            .read_by_type_req => |p| p.encode(dest),
            .read_by_type_rsp => AttError.InvalidOpcode,
            .read_req => |p| p.encode(dest),
            .read_rsp => |p| p.encode(dest),
            .read_blob_req => |p| p.encode(dest),
            .read_blob_rsp => |p| p.encode(dest),
            .read_multiple_req => AttError.InvalidOpcode,
            .read_multiple_rsp => |p| p.encode(dest),
            .read_by_group_type_req => |p| p.encode(dest),
            .read_by_group_type_rsp => AttError.InvalidOpcode,
            .write_req => |p| p.encode(dest),
            .write_rsp => WriteResponse.encode(dest),
            .write_cmd => |p| p.encode(dest),
            .signed_write_cmd => AttError.InvalidOpcode,
            .prepare_write_req => |p| p.encode(dest),
            .prepare_write_rsp => |p| p.encode(dest),
            .execute_write_req => |p| p.encode(dest),
            .execute_write_rsp => ExecuteWriteResponse.encode(dest),
            .handle_value_ntf => |p| p.encode(dest),
            .handle_value_ind => |p| p.encode(dest),
            .handle_value_cfm => HandleValueConfirmation.encode(dest),
        };
    }
};

// ============================================================================
