//! # Attribute Protocol (ATT) Bearer State Machine
const std = @import("std");
const core_types = @import("../types.zig");
const UUID = core_types.UUID;
const att_types = @import("types.zig");
const pdu_mod = @import("pdu.zig");

pub const AttOpcode = att_types.AttOpcode;
pub const AttErrorCode = att_types.AttErrorCode;
pub const AttError = att_types.AttError;
pub const AttPdu = pdu_mod.AttPdu;
pub const ErrorResponse = pdu_mod.ErrorResponse;
pub const ExchangeMtuResponse = pdu_mod.ExchangeMtuResponse;
pub const ReadResponse = pdu_mod.ReadResponse;
pub const ReadBlobResponse = pdu_mod.ReadBlobResponse;
pub const WriteResponse = pdu_mod.WriteResponse;
pub const WriteCommand = pdu_mod.WriteCommand;
pub const ExecuteWriteRequest = pdu_mod.ExecuteWriteRequest;
pub const PrepareWriteResponse = pdu_mod.PrepareWriteResponse;
pub const ExecuteWriteResponse = pdu_mod.ExecuteWriteResponse;
pub const SignedWriteCommand = pdu_mod.SignedWriteCommand;
pub const HandleValueNotification = pdu_mod.HandleValueNotification;
pub const HandleValueIndication = pdu_mod.HandleValueIndication;
pub const HandleValueConfirmation = pdu_mod.HandleValueConfirmation;


// ============================================================================
// ATT Transaction State Machine (Client & Server over L2CAP CID 0x0004)
// Bluetooth Core Specification Vol 3, Part F, Section 3.3.2 & 3.3.3
// ============================================================================

/// Fixed L2CAP Channel Identifier for the Attribute Protocol (ATT).
pub const ATT_CID: u16 = 0x0004;

/// Default ATT_MTU for LE Unenhanced ATT bearer (23 octets).
pub const DEFAULT_ATT_MTU: u16 = 23;

/// Maximum ATT_MTU per Bluetooth Core Specification (517 octets).
pub const MAX_ATT_MTU: u16 = 517;

/// Mandatory ATT transaction timeout (30 seconds = 30,000 ms) per Vol 3, Part F, Section 3.3.3.
pub const TRANSACTION_TIMEOUT_MS: u64 = 30_000;

/// Lifecycle state of an ATT Bearer.
pub const BearerState = enum {
    /// Connected and ready to initiate a client request.
    idle,
    /// Client request sent; awaiting matching response or ErrorResponse.
    waiting_response,
    /// A transaction exceeded 30 seconds; no more requests/indications may be sent on this bearer.
    timed_out,
    /// Underlying L2CAP / HCI link is disconnected.
    disconnected,
};

/// Result returned when processing an incoming PDU on the Client side of an `AttBearer`.
pub const ClientRxEvent = union(enum) {
    /// Correlated response to the active client request.
    response: AttPdu,
    /// Asynchronous server notification (does not affect active client transaction).
    notification: HandleValueNotification,
    /// Asynchronous server indication plus the number of bytes written to `confirm_out_buf` (0x1E).
    indication: struct {
        indication: HandleValueIndication,
        confirm_len: usize,
    },
};

/// Server attribute entry for `AttBearer.handleServerRx`.
pub const AttServerAttribute = struct {
    handle: u16,
    uuid: UUID,
    end_group_handle: u16 = 0,
    permissions: struct {
        readable: bool = true,
        writable: bool = false,
        encrypt_required: bool = false,
        authn_required: bool = false,
    } = .{},
    value: []u8,
    value_len: usize,
};

/// Queued PrepareWrite entry stored in the bearer for atomic `ExecuteWriteRequest`.
pub const PreparedWriteEntry = struct {
    handle: u16 = 0,
    offset: u16 = 0,
    data: [64]u8 = @splat(0),
    len: usize = 0,
};

/// Stateful ATT Bearer managing Client & Server transactions over L2CAP CID `0x0004`.
pub const AttBearer = struct {
    state: BearerState = .idle,
    mtu: u16 = DEFAULT_ATT_MTU,
    local_max_mtu: u16 = MAX_ATT_MTU,
    pending_request_opcode: ?AttOpcode = null,
    request_sent_ms: u64 = 0,
    indication_pending_confirm: bool = false,
    indication_sent_ms: u64 = 0,
    link_encrypted: bool = false,
    link_authenticated: bool = false,
    prep_queue: [8]PreparedWriteEntry = @splat(.{}),
    prep_queue_count: usize = 0,

    /// Maps a client request opcode to its expected positive response opcode.
    pub fn expectedResponseOpcode(req_op: AttOpcode) ?AttOpcode {
        return switch (req_op) {
            .exchange_mtu_req => .exchange_mtu_rsp,
            .find_info_req => .find_info_rsp,
            .find_by_type_val_req => .find_by_type_val_rsp,
            .read_by_type_req => .read_by_type_rsp,
            .read_req => .read_rsp,
            .read_blob_req => .read_blob_rsp,
            .read_multiple_req => .read_multiple_rsp,
            .read_by_group_type_req => .read_by_group_type_rsp,
            .write_req => .write_rsp,
            .prepare_write_req => .prepare_write_rsp,
            .execute_write_req => .execute_write_rsp,
            else => null,
        };
    }

    /// Resets bearer state upon establishing a new BLE connection.
    pub fn onConnect(self: *AttBearer) void {
        self.state = .idle;
        self.mtu = DEFAULT_ATT_MTU;
        self.pending_request_opcode = null;
        self.request_sent_ms = 0;
        self.indication_pending_confirm = false;
        self.indication_sent_ms = 0;
        self.link_encrypted = false;
        self.link_authenticated = false;
        self.prep_queue_count = 0;
    }

    /// Handles link disconnection. If a transaction was in flight, returns `AttError.BearerDisconnected`.
    pub fn onDisconnect(self: *AttBearer) AttError!void {
        const had_active_tx = (self.state == .waiting_response) or self.indication_pending_confirm;
        self.state = .disconnected;
        self.pending_request_opcode = null;
        self.indication_pending_confirm = false;
        self.prep_queue_count = 0;
        if (had_active_tx) return AttError.BearerDisconnected;
    }

    /// Checks whether the active client request or server indication has exceeded the 30s timeout.
    pub fn checkTimeout(self: *AttBearer, now_ms: u64) AttError!void {
        if (self.state == .waiting_response) {
            if (now_ms -| self.request_sent_ms >= TRANSACTION_TIMEOUT_MS) {
                self.state = .timed_out;
                self.pending_request_opcode = null;
                return AttError.TransactionTimeout;
            }
        }
        if (self.indication_pending_confirm) {
            if (now_ms -| self.indication_sent_ms >= TRANSACTION_TIMEOUT_MS) {
                self.state = .timed_out;
                self.indication_pending_confirm = false;
                return AttError.TransactionTimeout;
            }
        }
    }

    /// Begins a client request transaction, enforcing Sequential Flow Control (Vol 3, Part F, 3.3.2).
    pub fn beginRequest(self: *AttBearer, req_pdu: AttPdu, now_ms: u64, out_buf: []u8) AttError!usize {
        switch (self.state) {
            .disconnected => return AttError.BearerDisconnected,
            .timed_out => return AttError.BearerTimedOut,
            .waiting_response => return AttError.TransactionInProgress,
            .idle => {},
        }

        const effective_cap = @min(out_buf.len, @as(usize, self.mtu));
        const encoded_len = try req_pdu.serialize(out_buf[0..effective_cap]);
        const req_op: AttOpcode = @enumFromInt(out_buf[0]);
        if (expectedResponseOpcode(req_op) == null) return AttError.InvalidOpcode;

        if (req_pdu == .exchange_mtu_req) {
            if (req_pdu.exchange_mtu_req.client_rx_mtu < DEFAULT_ATT_MTU) return AttError.InvalidMtu;
            self.local_max_mtu = req_pdu.exchange_mtu_req.client_rx_mtu;
        }

        self.state = .waiting_response;
        self.pending_request_opcode = req_op;
        self.request_sent_ms = now_ms;
        return encoded_len;
    }

    /// Sends an unacknowledged client command (`WriteCommand` or `SignedWriteCommand`) without starting a transaction.
    pub fn sendCommand(self: *const AttBearer, cmd_pdu: AttPdu, out_buf: []u8) AttError!usize {
        if (self.state == .disconnected) return AttError.BearerDisconnected;
        if (self.state == .timed_out) return AttError.BearerTimedOut;
        if (cmd_pdu != .write_cmd and cmd_pdu != .signed_write_cmd) return AttError.InvalidOpcode;

        const effective_cap = @min(out_buf.len, @as(usize, self.mtu));
        return cmd_pdu.serialize(out_buf[0..effective_cap]);
    }

    /// Processes an incoming PDU on the Client bearer, correlating responses and auto-confirming indications.
    pub fn handleClientRx(self: *AttBearer, raw_pdu: []const u8, confirm_out_buf: ?[]u8) AttError!ClientRxEvent {
        if (self.state == .disconnected) return AttError.BearerDisconnected;
        if (self.state == .timed_out) return AttError.BearerTimedOut;
        if (raw_pdu.len == 0) return AttError.PayloadTooShort;

        const pdu = try AttPdu.parse(raw_pdu);

        // Server-initiated PDUs may arrive at any time, even while a client request is pending.
        switch (pdu) {
            .handle_value_ntf => |ntf| return .{ .notification = ntf },
            .handle_value_ind => |ind| {
                var cfm_len: usize = 0;
                if (confirm_out_buf) |buf| {
                    cfm_len = try HandleValueConfirmation.encode(buf);
                }
                return .{ .indication = .{ .indication = ind, .confirm_len = cfm_len } };
            },
            else => {},
        }

        // Response correlation
        if (self.state != .waiting_response or self.pending_request_opcode == null) {
            return AttError.UnexpectedResponse;
        }

        const pending_op = self.pending_request_opcode.?;
        if (pdu == .error_rsp) {
            if (pdu.error_rsp.request_opcode != @intFromEnum(pending_op)) {
                return AttError.UnexpectedOpcode;
            }
            self.state = .idle;
            self.pending_request_opcode = null;
            return pdu.error_rsp.error_code.toError();
        }

        const expected_op = expectedResponseOpcode(pending_op) orelse return AttError.UnexpectedOpcode;
        const actual_op: AttOpcode = @enumFromInt(raw_pdu[0]);
        if (actual_op != expected_op) {
            return AttError.UnexpectedOpcode;
        }

        if (pdu == .exchange_mtu_rsp) {
            if (pdu.exchange_mtu_rsp.server_rx_mtu < DEFAULT_ATT_MTU) {
                self.state = .idle;
                self.pending_request_opcode = null;
                return AttError.InvalidMtu;
            }
            self.mtu = @max(DEFAULT_ATT_MTU, @min(self.local_max_mtu, pdu.exchange_mtu_rsp.server_rx_mtu));
        }

        self.state = .idle;
        self.pending_request_opcode = null;
        return .{ .response = pdu };
    }

    /// Sends a server-initiated indication (`0x1D`), enforcing single-indication-in-flight rule.
    pub fn beginServerIndication(self: *AttBearer, ind: HandleValueIndication, now_ms: u64, out_buf: []u8) AttError!usize {
        if (self.state == .disconnected) return AttError.BearerDisconnected;
        if (self.state == .timed_out) return AttError.BearerTimedOut;
        if (self.indication_pending_confirm) return AttError.TransactionInProgress;

        const effective_cap = @min(out_buf.len, @as(usize, self.mtu));
        const len = try ind.encode(out_buf[0..effective_cap]);
        self.indication_pending_confirm = true;
        self.indication_sent_ms = now_ms;
        return len;
    }

    /// Processes an incoming client request/command/confirmation on the Server side of the bearer.
    /// Returns the number of response bytes written to `out_buf` (0 for `WriteCommand` or `HandleValueConfirmation`).
    pub fn handleServerRx(self: *AttBearer, raw_pdu: []const u8, db: []AttServerAttribute, out_buf: []u8) AttError!usize {
        if (self.state == .disconnected) return AttError.BearerDisconnected;
        if (self.state == .timed_out) return AttError.BearerTimedOut;
        if (raw_pdu.len == 0) return AttError.PayloadTooShort;

        const req_op_raw = raw_pdu[0];
        const pdu = AttPdu.parse(raw_pdu) catch |err| {
            const err_code: AttErrorCode = switch (err) {
                error.InvalidOpcode => .request_not_supported,
                else => .invalid_pdu,
            };
            return (ErrorResponse{
                .request_opcode = req_op_raw,
                .handle = 0x0000,
                .error_code = err_code,
            }).encode(out_buf);
        };

        switch (pdu) {
            .handle_value_cfm => {
                if (!self.indication_pending_confirm) return AttError.UnexpectedResponse;
                self.indication_pending_confirm = false;
                return 0;
            },
            .exchange_mtu_req => |req| {
                if (req.client_rx_mtu < DEFAULT_ATT_MTU) {
                    return (ErrorResponse{
                        .request_opcode = req_op_raw,
                        .handle = 0x0000,
                        .error_code = .invalid_pdu,
                    }).encode(out_buf);
                }
                self.mtu = @max(DEFAULT_ATT_MTU, @min(self.local_max_mtu, req.client_rx_mtu));
                return (ExchangeMtuResponse{ .server_rx_mtu = self.local_max_mtu }).encode(out_buf);
            },
            .read_req => |req| {
                for (db) |*attr| {
                    if (attr.handle == req.handle) {
                        if (!attr.permissions.readable) {
                            return (ErrorResponse{ .request_opcode = req_op_raw, .handle = req.handle, .error_code = .read_not_permitted }).encode(out_buf);
                        }
                        if (attr.permissions.encrypt_required and !self.link_encrypted) {
                            return (ErrorResponse{ .request_opcode = req_op_raw, .handle = req.handle, .error_code = .insufficient_encryption }).encode(out_buf);
                        }
                        if (attr.permissions.authn_required and !self.link_authenticated) {
                            return (ErrorResponse{ .request_opcode = req_op_raw, .handle = req.handle, .error_code = .insufficient_authentication }).encode(out_buf);
                        }
                        const max_val = @min(attr.value_len, @as(usize, self.mtu) - 1);
                        return (ReadResponse{ .value = attr.value[0..max_val] }).encode(out_buf);
                    }
                }
                return (ErrorResponse{ .request_opcode = req_op_raw, .handle = req.handle, .error_code = .invalid_handle }).encode(out_buf);
            },
            .read_blob_req => |req| {
                for (db) |*attr| {
                    if (attr.handle == req.handle) {
                        if (!attr.permissions.readable) {
                            return (ErrorResponse{ .request_opcode = req_op_raw, .handle = req.handle, .error_code = .read_not_permitted }).encode(out_buf);
                        }
                        if (req.offset > attr.value_len) {
                            return (ErrorResponse{ .request_opcode = req_op_raw, .handle = req.handle, .error_code = .invalid_offset }).encode(out_buf);
                        }
                        const remaining = attr.value_len - req.offset;
                        const chunk_len = @min(remaining, @as(usize, self.mtu) - 1);
                        return (ReadBlobResponse{ .part_value = attr.value[req.offset .. req.offset + chunk_len] }).encode(out_buf);
                    }
                }
                return (ErrorResponse{ .request_opcode = req_op_raw, .handle = req.handle, .error_code = .invalid_handle }).encode(out_buf);
            },
            .write_req => |req| {
                for (db) |*attr| {
                    if (attr.handle == req.handle) {
                        if (!attr.permissions.writable) {
                            return (ErrorResponse{ .request_opcode = req_op_raw, .handle = req.handle, .error_code = .write_not_permitted }).encode(out_buf);
                        }
                        if (attr.permissions.encrypt_required and !self.link_encrypted) {
                            return (ErrorResponse{ .request_opcode = req_op_raw, .handle = req.handle, .error_code = .insufficient_encryption }).encode(out_buf);
                        }
                        if (req.value.len > attr.value.len) {
                            return (ErrorResponse{ .request_opcode = req_op_raw, .handle = req.handle, .error_code = .invalid_attribute_value_length }).encode(out_buf);
                        }
                        @memcpy(attr.value[0..req.value.len], req.value);
                        attr.value_len = req.value.len;
                        return WriteResponse.encode(out_buf);
                    }
                }
                return (ErrorResponse{ .request_opcode = req_op_raw, .handle = req.handle, .error_code = .invalid_handle }).encode(out_buf);
            },
            .write_cmd => |cmd| {
                for (db) |*attr| {
                    if (attr.handle == cmd.handle and attr.permissions.writable and cmd.value.len <= attr.value.len) {
                        @memcpy(attr.value[0..cmd.value.len], cmd.value);
                        attr.value_len = cmd.value.len;
                        break;
                    }
                }
                return 0;
            },
            .prepare_write_req => |req| {
                if (self.prep_queue_count >= self.prep_queue.len or req.part_value.len > 64) {
                    return (ErrorResponse{ .request_opcode = req_op_raw, .handle = req.handle, .error_code = .prepare_queue_full }).encode(out_buf);
                }
                var entry = &self.prep_queue[self.prep_queue_count];
                entry.handle = req.handle;
                entry.offset = req.offset;
                entry.len = req.part_value.len;
                @memcpy(entry.data[0..req.part_value.len], req.part_value);
                self.prep_queue_count += 1;
                return (PrepareWriteResponse{
                    .handle = req.handle,
                    .offset = req.offset,
                    .part_value = req.part_value,
                }).encode(out_buf);
            },
            .execute_write_req => |req| {
                defer self.prep_queue_count = 0;
                if (req.flags == .commit) {
                    for (self.prep_queue[0..self.prep_queue_count]) |entry| {
                        var found = false;
                        for (db) |*attr| {
                            if (attr.handle == entry.handle) {
                                found = true;
                                if (!attr.permissions.writable) {
                                    return (ErrorResponse{ .request_opcode = req_op_raw, .handle = entry.handle, .error_code = .write_not_permitted }).encode(out_buf);
                                }
                                if (entry.offset > attr.value_len) {
                                    return (ErrorResponse{ .request_opcode = req_op_raw, .handle = entry.handle, .error_code = .invalid_offset }).encode(out_buf);
                                }
                                if (entry.offset + entry.len > attr.value.len) {
                                    return (ErrorResponse{ .request_opcode = req_op_raw, .handle = entry.handle, .error_code = .invalid_attribute_value_length }).encode(out_buf);
                                }
                                @memcpy(attr.value[entry.offset .. entry.offset + entry.len], entry.data[0..entry.len]);
                                if (entry.offset + entry.len > attr.value_len) {
                                    attr.value_len = entry.offset + entry.len;
                                }
                                break;
                            }
                        }
                        if (!found) {
                            return (ErrorResponse{ .request_opcode = req_op_raw, .handle = entry.handle, .error_code = .invalid_handle }).encode(out_buf);
                        }
                    }
                }
                return ExecuteWriteResponse.encode(out_buf);
            },
            else => {
                return (ErrorResponse{
                    .request_opcode = req_op_raw,
                    .handle = 0x0000,
                    .error_code = .request_not_supported,
                }).encode(out_buf);
            },
        }
    }
};

