//! # Security Manager Protocol (SMP) Types & Constants
const std = @import("std");

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
    UnexpectedOpcode,
    DuplicatePdu,
    ConfirmValueFailed,
    DhKeyCheckFailed,
    PairingTimeout,
    BearerDisconnected,
    EntropyUnavailable,
};

// -------------------------------------------------------------------------------------------------
// SMP PDU Definitions
// -------------------------------------------------------------------------------------------------


/// Fixed L2CAP Channel Identifier for the Security Manager Protocol (SMP).
pub const SMP_CID: u16 = 0x0006;

/// Mandatory SMP timer timeout (30 seconds = 30,000 ms) per Vol 3, Part H, Section 3.4.
pub const SMP_TIMEOUT_MS: u64 = 30_000;

pub const SmpRole = enum {
    initiator,
    responder,
};

pub const PairingMethod = enum {
    just_works,
    numeric_comparison,
    passkey_entry,
    oob,
};

pub const SmpState = enum {
    idle,
    wait_pairing_response,
    wait_public_key,
    wait_confirm,
    wait_random,
    wait_dhkey_check,
    key_distribution,
    completed,
    failed,
    timed_out,
    disconnected,
};

