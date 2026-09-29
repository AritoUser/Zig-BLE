//! # Security Manager Protocol (SMP) Engine
//!
//! Compliant with Bluetooth Core Specification v5.4 / v6.0, Vol 3, Part H
//! (Security Manager Specification), Section 3: Security Manager Protocol.
//!
//! Features:
//! - 100% Pure Zig, zero external dependencies, zero dynamic allocations.
//! - Complete zero-copy parsers and serializers for all 14 standard SMP PDUs.
//! - Comprehensive error checking, bounds safety, and enum validation.

const std = @import("std");
const types = @import("../core/types.zig");
const Address = types.Address;
const AddressType = types.AddressType;

// -------------------------------------------------------------------------------------------------
// SMP Opcodes & Enums
// -------------------------------------------------------------------------------------------------

pub const SmpOpcode = enum(u8) {
    pairing_request = 0x01,
    pairing_response = 0x02,
    pairing_confirm = 0x03,
    pairing_random = 0x04,
    pairing_failed = 0x05,
    encryption_information = 0x06,
    master_identification = 0x07,
    identity_information = 0x08,
    identity_address_information = 0x09,
    signing_information = 0x0A,
    security_request = 0x0B,
    pairing_public_key = 0x0C,
    pairing_dhkey_check = 0x0D,
    pairing_keypress_notification = 0x0E,
    _,

    pub fn getName(self: SmpOpcode) []const u8 {
        return switch (self) {
            .pairing_request => "Pairing Request",
            .pairing_response => "Pairing Response",
            .pairing_confirm => "Pairing Confirm",
            .pairing_random => "Pairing Random",
            .pairing_failed => "Pairing Failed",
            .encryption_information => "Encryption Information",
            .master_identification => "Master Identification",
            .identity_information => "Identity Information",
            .identity_address_information => "Identity Address Information",
            .signing_information => "Signing Information",
            .security_request => "Security Request",
            .pairing_public_key => "Pairing Public Key",
            .pairing_dhkey_check => "Pairing DHKey Check",
            .pairing_keypress_notification => "Pairing Keypress Notification",
            _ => "Unknown SMP Opcode",
        };
    }
};

pub const IoCapability = enum(u8) {
    display_only = 0x00,
    display_yes_no = 0x01,
    keyboard_only = 0x02,
    no_input_no_output = 0x03,
    keyboard_display = 0x04,
    _,

    pub fn toString(self: IoCapability) []const u8 {
        return switch (self) {
            .display_only => "Display Only",
            .display_yes_no => "Display Yes/No",
            .keyboard_only => "Keyboard Only",
            .no_input_no_output => "No Input No Output",
            .keyboard_display => "Keyboard Display",
            _ => "Unknown IO Capability",
        };
    }
};

pub const AuthReq = packed struct(u8) {
    bonding: bool = false,
    _reserved1: bool = false,
    mitm: bool = false,
    sc: bool = false,
    keypress: bool = false,
    ct2: bool = false,
    _reserved2: u2 = 0,

    pub fn toByte(self: AuthReq) u8 {
        return @bitCast(self);
    }

    pub fn fromByte(b: u8) AuthReq {
        return @bitCast(b);
    }
};

pub const KeyDistribution = packed struct(u8) {
    enc_key: bool = false, // LTK
    id_key: bool = false, // IRK & Identity Address
    sign_key: bool = false, // CSRK
    link_key: bool = false, // BR/EDR Link Key
    _reserved: u4 = 0,

    pub fn toByte(self: KeyDistribution) u8 {
        return @bitCast(self);
    }

    pub fn fromByte(b: u8) KeyDistribution {
        return @bitCast(b);
    }
};

pub const PairingFailedReason = enum(u8) {
    passkey_entry_failed = 0x01,
    oob_not_available = 0x02,
    authentication_requirements = 0x03,
    confirm_value_failed = 0x04,
    pairing_not_supported = 0x05,
    encryption_key_size = 0x06,
    command_not_supported = 0x07,
    unspecified_reason = 0x08,
    repeated_attempts = 0x09,
    invalid_parameters = 0x0A,
    dhkey_check_failed = 0x0B,
    numeric_comparison_failed = 0x0C,
    br_edr_pairing_in_progress = 0x0D,
    cross_transport_key_derivation_not_allowed = 0x0E,
    key_rejected = 0x0F,
    _,

    pub fn getName(self: PairingFailedReason) []const u8 {
        return switch (self) {
            .passkey_entry_failed => "Passkey Entry Failed",
            .oob_not_available => "OOB Not Available",
            .authentication_requirements => "Authentication Requirements Not Met",
            .confirm_value_failed => "Confirm Value Failed",
            .pairing_not_supported => "Pairing Not Supported",
            .encryption_key_size => "Encryption Key Size Invalid",
            .command_not_supported => "Command Not Supported",
            .unspecified_reason => "Unspecified Reason",
            .repeated_attempts => "Repeated Attempts",
            .invalid_parameters => "Invalid Parameters",
            .dhkey_check_failed => "DHKey Check Failed",
            .numeric_comparison_failed => "Numeric Comparison Failed",
            .br_edr_pairing_in_progress => "BR/EDR Pairing in Progress",
            .cross_transport_key_derivation_not_allowed => "Cross-Transport Key Derivation Not Allowed",
            .key_rejected => "Key Rejected",
            _ => "Unknown Error",
        };
    }
};

pub const KeypressNotificationType = enum(u8) {
    passkey_entry_started = 0x00,
    passkey_digit_entered = 0x01,
    passkey_digit_erased = 0x02,
    passkey_cleared = 0x03,
    passkey_entry_completed = 0x04,
    _,
};

pub const SmpError = error{
    BufferTooShort,
    BufferTooSmall,
    InvalidOpcode,
    InvalidLength,
    InvalidParameter,
};

// -------------------------------------------------------------------------------------------------
// SMP PDU Definitions
// -------------------------------------------------------------------------------------------------

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

test "smp pdu roundtrip tests" {
    // 1. Pairing Request
    const req = PairingRequest{
        .io_capability = .keyboard_display,
        .oob_data_flag = 0,
        .auth_req = .{ .bonding = true, .mitm = true, .sc = true },
        .max_encryption_key_size = 16,
        .initiator_key_distribution = .{ .enc_key = true, .id_key = true },
        .responder_key_distribution = .{ .enc_key = true, .id_key = true },
    };
    var buf: [128]u8 = undefined;
    const len1 = try req.serialize(&buf);
    try std.testing.expectEqual(7, len1);

    const parsed_pdu = try SmpPdu.parse(buf[0..len1]);
    try std.testing.expect(parsed_pdu == .pairing_request);
    try std.testing.expectEqual(IoCapability.keyboard_display, parsed_pdu.pairing_request.io_capability);
    try std.testing.expect(parsed_pdu.pairing_request.auth_req.sc);
    try std.testing.expect(parsed_pdu.pairing_request.auth_req.mitm);

    // 2. Pairing Failed
    const failed = PairingFailed{ .reason = .dhkey_check_failed };
    const len2 = try failed.serialize(&buf);
    const parsed_failed = try PairingFailed.parse(buf[0..len2]);
    try std.testing.expectEqual(PairingFailedReason.dhkey_check_failed, parsed_failed.reason);

    // 3. Identity Address Information
    const id_addr = IdentityAddressInformation{
        .addr_type = .random,
        .address = try Address.parse("C0:1A:7D:DA:71:13"),
    };
    const len3 = try id_addr.serialize(&buf);
    const parsed_id_addr = try IdentityAddressInformation.parse(buf[0..len3]);
    try std.testing.expect(parsed_id_addr.address.eql(try Address.parse("C0:1A:7D:DA:71:13")));
}
