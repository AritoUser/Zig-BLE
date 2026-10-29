//! # Security Manager Protocol (SMP) PDUs & Encoders
const std = @import("std");
const core_types = @import("../../core/types.zig");
const types_mod = @import("types.zig");

pub const Address = core_types.Address;
pub const AddressType = core_types.AddressType;
pub const SmpOpcode = types_mod.SmpOpcode;
pub const IoCapability = types_mod.IoCapability;
pub const AuthReq = types_mod.AuthReq;
pub const KeyDistribution = types_mod.KeyDistribution;
pub const PairingFailedReason = types_mod.PairingFailedReason;
pub const KeypressNotificationType = types_mod.KeypressNotificationType;
pub const SmpError = types_mod.SmpError;

pub const PairingRequest = struct {
    io_capability: IoCapability,
    oob_data_flag: u8,
    auth_req: AuthReq,
    max_encryption_key_size: u8,
    initiator_key_distribution: KeyDistribution,
    responder_key_distribution: KeyDistribution,

    pub const PDU_LEN: usize = 7;

    pub fn parse(raw: []const u8) SmpError!PairingRequest {
        if (raw.len < PDU_LEN) return SmpError.BufferTooShort;
        if (raw[0] != @intFromEnum(SmpOpcode.pairing_request)) return SmpError.InvalidOpcode;

        return PairingRequest{
            .io_capability = @enumFromInt(raw[1]),
            .oob_data_flag = raw[2],
            .auth_req = AuthReq.fromByte(raw[3]),
            .max_encryption_key_size = raw[4],
            .initiator_key_distribution = KeyDistribution.fromByte(raw[5]),
            .responder_key_distribution = KeyDistribution.fromByte(raw[6]),
        };
    }

    pub fn serialize(self: PairingRequest, dest: []u8) SmpError!usize {
        if (dest.len < PDU_LEN) return SmpError.BufferTooSmall;
        dest[0] = @intFromEnum(SmpOpcode.pairing_request);
        dest[1] = @intFromEnum(self.io_capability);
        dest[2] = self.oob_data_flag;
        dest[3] = self.auth_req.toByte();
        dest[4] = self.max_encryption_key_size;
        dest[5] = self.initiator_key_distribution.toByte();
        dest[6] = self.responder_key_distribution.toByte();
        return PDU_LEN;
    }
};

pub const PairingResponse = struct {
    io_capability: IoCapability,
    oob_data_flag: u8,
    auth_req: AuthReq,
    max_encryption_key_size: u8,
    initiator_key_distribution: KeyDistribution,
    responder_key_distribution: KeyDistribution,

    pub const PDU_LEN: usize = 7;

    pub fn parse(raw: []const u8) SmpError!PairingResponse {
        if (raw.len < PDU_LEN) return SmpError.BufferTooShort;
        if (raw[0] != @intFromEnum(SmpOpcode.pairing_response)) return SmpError.InvalidOpcode;

        return PairingResponse{
            .io_capability = @enumFromInt(raw[1]),
            .oob_data_flag = raw[2],
            .auth_req = AuthReq.fromByte(raw[3]),
            .max_encryption_key_size = raw[4],
            .initiator_key_distribution = KeyDistribution.fromByte(raw[5]),
            .responder_key_distribution = KeyDistribution.fromByte(raw[6]),
        };
    }

    pub fn serialize(self: PairingResponse, dest: []u8) SmpError!usize {
        if (dest.len < PDU_LEN) return SmpError.BufferTooSmall;
        dest[0] = @intFromEnum(SmpOpcode.pairing_response);
        dest[1] = @intFromEnum(self.io_capability);
        dest[2] = self.oob_data_flag;
        dest[3] = self.auth_req.toByte();
        dest[4] = self.max_encryption_key_size;
        dest[5] = self.initiator_key_distribution.toByte();
        dest[6] = self.responder_key_distribution.toByte();
        return PDU_LEN;
    }
};

pub const PairingConfirm = struct {
    confirm_value: [16]u8,

    pub const PDU_LEN: usize = 17;

    pub fn parse(raw: []const u8) SmpError!PairingConfirm {
        if (raw.len < PDU_LEN) return SmpError.BufferTooShort;
        if (raw[0] != @intFromEnum(SmpOpcode.pairing_confirm)) return SmpError.InvalidOpcode;

        return PairingConfirm{
            .confirm_value = raw[1..17].*,
        };
    }

    pub fn serialize(self: PairingConfirm, dest: []u8) SmpError!usize {
        if (dest.len < PDU_LEN) return SmpError.BufferTooSmall;
        dest[0] = @intFromEnum(SmpOpcode.pairing_confirm);
        @memcpy(dest[1..17], &self.confirm_value);
        return PDU_LEN;
    }
};

pub const PairingRandom = struct {
    random_value: [16]u8,

    pub const PDU_LEN: usize = 17;

    pub fn parse(raw: []const u8) SmpError!PairingRandom {
        if (raw.len < PDU_LEN) return SmpError.BufferTooShort;
        if (raw[0] != @intFromEnum(SmpOpcode.pairing_random)) return SmpError.InvalidOpcode;

        return PairingRandom{
            .random_value = raw[1..17].*,
        };
    }

    pub fn serialize(self: PairingRandom, dest: []u8) SmpError!usize {
        if (dest.len < PDU_LEN) return SmpError.BufferTooSmall;
        dest[0] = @intFromEnum(SmpOpcode.pairing_random);
        @memcpy(dest[1..17], &self.random_value);
        return PDU_LEN;
    }
};

pub const PairingFailed = struct {
    reason: PairingFailedReason,

    pub const PDU_LEN: usize = 2;

    pub fn parse(raw: []const u8) SmpError!PairingFailed {
        if (raw.len < PDU_LEN) return SmpError.BufferTooShort;
        if (raw[0] != @intFromEnum(SmpOpcode.pairing_failed)) return SmpError.InvalidOpcode;

        return PairingFailed{
            .reason = @enumFromInt(raw[1]),
        };
    }

    pub fn serialize(self: PairingFailed, dest: []u8) SmpError!usize {
        if (dest.len < PDU_LEN) return SmpError.BufferTooSmall;
        dest[0] = @intFromEnum(SmpOpcode.pairing_failed);
        dest[1] = @intFromEnum(self.reason);
        return PDU_LEN;
    }
};

pub const EncryptionInformation = struct {
    long_term_key: [16]u8,

    pub const PDU_LEN: usize = 17;

    pub fn parse(raw: []const u8) SmpError!EncryptionInformation {
        if (raw.len < PDU_LEN) return SmpError.BufferTooShort;
        if (raw[0] != @intFromEnum(SmpOpcode.encryption_information)) return SmpError.InvalidOpcode;

        return EncryptionInformation{
            .long_term_key = raw[1..17].*,
        };
    }

    pub fn serialize(self: EncryptionInformation, dest: []u8) SmpError!usize {
        if (dest.len < PDU_LEN) return SmpError.BufferTooSmall;
        dest[0] = @intFromEnum(SmpOpcode.encryption_information);
        @memcpy(dest[1..17], &self.long_term_key);
        return PDU_LEN;
    }
};

pub const MasterIdentification = struct {
    ediv: u16,
    rand: [8]u8,

    pub const PDU_LEN: usize = 11;

    pub fn parse(raw: []const u8) SmpError!MasterIdentification {
        if (raw.len < PDU_LEN) return SmpError.BufferTooShort;
        if (raw[0] != @intFromEnum(SmpOpcode.master_identification)) return SmpError.InvalidOpcode;

        return MasterIdentification{
            .ediv = std.mem.readInt(u16, raw[1..3], .little),
            .rand = raw[3..11].*,
        };
    }

    pub fn serialize(self: MasterIdentification, dest: []u8) SmpError!usize {
        if (dest.len < PDU_LEN) return SmpError.BufferTooSmall;
        dest[0] = @intFromEnum(SmpOpcode.master_identification);
        std.mem.writeInt(u16, dest[1..3], self.ediv, .little);
        @memcpy(dest[3..11], &self.rand);
        return PDU_LEN;
    }
};

pub const IdentityInformation = struct {
    irk: [16]u8,

    pub const PDU_LEN: usize = 17;

    pub fn parse(raw: []const u8) SmpError!IdentityInformation {
        if (raw.len < PDU_LEN) return SmpError.BufferTooShort;
        if (raw[0] != @intFromEnum(SmpOpcode.identity_information)) return SmpError.InvalidOpcode;

        return IdentityInformation{
            .irk = raw[1..17].*,
        };
    }

    pub fn serialize(self: IdentityInformation, dest: []u8) SmpError!usize {
        if (dest.len < PDU_LEN) return SmpError.BufferTooSmall;
        dest[0] = @intFromEnum(SmpOpcode.identity_information);
        @memcpy(dest[1..17], &self.irk);
        return PDU_LEN;
    }
};

pub const IdentityAddressInformation = struct {
    addr_type: AddressType,
    address: Address,

    pub const PDU_LEN: usize = 8;

    pub fn parse(raw: []const u8) SmpError!IdentityAddressInformation {
        if (raw.len < PDU_LEN) return SmpError.BufferTooShort;
        if (raw[0] != @intFromEnum(SmpOpcode.identity_address_information)) return SmpError.InvalidOpcode;

        const at: AddressType = if (raw[1] == 0) .public else .random;

        // Bluetooth address on wire is Little-Endian (6 bytes)
        // Address.bytes is Big-Endian in memory
        var addr_bytes: [6]u8 = undefined;
        for (0..6) |i| {
            addr_bytes[5 - i] = raw[2 + i];
        }

        return IdentityAddressInformation{
            .addr_type = at,
            .address = Address{ .bytes = addr_bytes },
        };
    }

    pub fn serialize(self: IdentityAddressInformation, dest: []u8) SmpError!usize {
        if (dest.len < PDU_LEN) return SmpError.BufferTooSmall;
        dest[0] = @intFromEnum(SmpOpcode.identity_address_information);
        dest[1] = if (self.addr_type == .public) 0x00 else 0x01;
        for (0..6) |i| {
            dest[2 + i] = self.address.bytes[5 - i];
        }
        return PDU_LEN;
    }
};

pub const SigningInformation = struct {
    csrk: [16]u8,

    pub const PDU_LEN: usize = 17;

    pub fn parse(raw: []const u8) SmpError!SigningInformation {
        if (raw.len < PDU_LEN) return SmpError.BufferTooShort;
        if (raw[0] != @intFromEnum(SmpOpcode.signing_information)) return SmpError.InvalidOpcode;

        return SigningInformation{
            .csrk = raw[1..17].*,
        };
    }

    pub fn serialize(self: SigningInformation, dest: []u8) SmpError!usize {
        if (dest.len < PDU_LEN) return SmpError.BufferTooSmall;
        dest[0] = @intFromEnum(SmpOpcode.signing_information);
        @memcpy(dest[1..17], &self.csrk);
        return PDU_LEN;
    }
};

pub const SecurityRequest = struct {
    auth_req: AuthReq,

    pub const PDU_LEN: usize = 2;

    pub fn parse(raw: []const u8) SmpError!SecurityRequest {
        if (raw.len < PDU_LEN) return SmpError.BufferTooShort;
        if (raw[0] != @intFromEnum(SmpOpcode.security_request)) return SmpError.InvalidOpcode;

        return SecurityRequest{
            .auth_req = AuthReq.fromByte(raw[1]),
        };
    }

    pub fn serialize(self: SecurityRequest, dest: []u8) SmpError!usize {
        if (dest.len < PDU_LEN) return SmpError.BufferTooSmall;
        dest[0] = @intFromEnum(SmpOpcode.security_request);
        dest[1] = self.auth_req.toByte();
        return PDU_LEN;
    }
};

pub const PairingPublicKey = struct {
    x: [32]u8,
    y: [32]u8,

    pub const PDU_LEN: usize = 65;

    pub fn parse(raw: []const u8) SmpError!PairingPublicKey {
        if (raw.len < PDU_LEN) return SmpError.BufferTooShort;
        if (raw[0] != @intFromEnum(SmpOpcode.pairing_public_key)) return SmpError.InvalidOpcode;

        return PairingPublicKey{
            .x = raw[1..33].*,
            .y = raw[33..65].*,
        };
    }

    pub fn serialize(self: PairingPublicKey, dest: []u8) SmpError!usize {
        if (dest.len < PDU_LEN) return SmpError.BufferTooSmall;
        dest[0] = @intFromEnum(SmpOpcode.pairing_public_key);
        @memcpy(dest[1..33], &self.x);
        @memcpy(dest[33..65], &self.y);
        return PDU_LEN;
    }
};

pub const PairingDhKeyCheck = struct {
    check_value: [16]u8,

    pub const PDU_LEN: usize = 17;

    pub fn parse(raw: []const u8) SmpError!PairingDhKeyCheck {
        if (raw.len < PDU_LEN) return SmpError.BufferTooShort;
        if (raw[0] != @intFromEnum(SmpOpcode.pairing_dhkey_check)) return SmpError.InvalidOpcode;

        return PairingDhKeyCheck{
            .check_value = raw[1..17].*,
        };
    }

    pub fn serialize(self: PairingDhKeyCheck, dest: []u8) SmpError!usize {
        if (dest.len < PDU_LEN) return SmpError.BufferTooSmall;
        dest[0] = @intFromEnum(SmpOpcode.pairing_dhkey_check);
        @memcpy(dest[1..17], &self.check_value);
        return PDU_LEN;
    }
};

pub const PairingKeypressNotification = struct {
    notification_type: KeypressNotificationType,

    pub const PDU_LEN: usize = 2;

    pub fn parse(raw: []const u8) SmpError!PairingKeypressNotification {
        if (raw.len < PDU_LEN) return SmpError.BufferTooShort;
        if (raw[0] != @intFromEnum(SmpOpcode.pairing_keypress_notification)) return SmpError.InvalidOpcode;

        return PairingKeypressNotification{
            .notification_type = @enumFromInt(raw[1]),
        };
    }

    pub fn serialize(self: PairingKeypressNotification, dest: []u8) SmpError!usize {
        if (dest.len < PDU_LEN) return SmpError.BufferTooSmall;
        dest[0] = @intFromEnum(SmpOpcode.pairing_keypress_notification);
        dest[1] = @intFromEnum(self.notification_type);
        return PDU_LEN;
    }
};

// -------------------------------------------------------------------------------------------------
// Tagged Union SmpPdu
// -------------------------------------------------------------------------------------------------

pub const SmpPdu = union(SmpOpcode) {
    pairing_request: PairingRequest,
    pairing_response: PairingResponse,
    pairing_confirm: PairingConfirm,
    pairing_random: PairingRandom,
    pairing_failed: PairingFailed,
    encryption_information: EncryptionInformation,
    master_identification: MasterIdentification,
    identity_information: IdentityInformation,
    identity_address_information: IdentityAddressInformation,
    signing_information: SigningInformation,
    security_request: SecurityRequest,
    pairing_public_key: PairingPublicKey,
    pairing_dhkey_check: PairingDhKeyCheck,
    pairing_keypress_notification: PairingKeypressNotification,

    pub fn parse(raw: []const u8) SmpError!SmpPdu {
        if (raw.len == 0) return SmpError.BufferTooShort;
        const opcode: SmpOpcode = @enumFromInt(raw[0]);

        return switch (opcode) {
            .pairing_request => .{ .pairing_request = try PairingRequest.parse(raw) },
            .pairing_response => .{ .pairing_response = try PairingResponse.parse(raw) },
            .pairing_confirm => .{ .pairing_confirm = try PairingConfirm.parse(raw) },
            .pairing_random => .{ .pairing_random = try PairingRandom.parse(raw) },
            .pairing_failed => .{ .pairing_failed = try PairingFailed.parse(raw) },
            .encryption_information => .{ .encryption_information = try EncryptionInformation.parse(raw) },
            .master_identification => .{ .master_identification = try MasterIdentification.parse(raw) },
            .identity_information => .{ .identity_information = try IdentityInformation.parse(raw) },
            .identity_address_information => .{ .identity_address_information = try IdentityAddressInformation.parse(raw) },
            .signing_information => .{ .signing_information = try SigningInformation.parse(raw) },
            .security_request => .{ .security_request = try SecurityRequest.parse(raw) },
            .pairing_public_key => .{ .pairing_public_key = try PairingPublicKey.parse(raw) },
            .pairing_dhkey_check => .{ .pairing_dhkey_check = try PairingDhKeyCheck.parse(raw) },
            .pairing_keypress_notification => .{ .pairing_keypress_notification = try PairingKeypressNotification.parse(raw) },
            _ => SmpError.InvalidOpcode,
        };
    }

    pub fn serialize(self: SmpPdu, dest: []u8) SmpError!usize {
        return switch (self) {
            .pairing_request => |p| p.serialize(dest),
            .pairing_response => |p| p.serialize(dest),
            .pairing_confirm => |p| p.serialize(dest),
            .pairing_random => |p| p.serialize(dest),
            .pairing_failed => |p| p.serialize(dest),
            .encryption_information => |p| p.serialize(dest),
            .master_identification => |p| p.serialize(dest),
            .identity_information => |p| p.serialize(dest),
            .identity_address_information => |p| p.serialize(dest),
            .signing_information => |p| p.serialize(dest),
            .security_request => |p| p.serialize(dest),
            .pairing_public_key => |p| p.serialize(dest),
            .pairing_dhkey_check => |p| p.serialize(dest),
            .pairing_keypress_notification => |p| p.serialize(dest),
        };
    }
};

// -------------------------------------------------------------------------------------------------
// Tests
// -------------------------------------------------------------------------------------------------

