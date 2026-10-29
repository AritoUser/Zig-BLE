//! # Attribute Protocol (ATT) Error Codes & Opcodes
const std = @import("std");
const gatt = @import("../gatt.zig");

pub const AttErrorCode = enum(u8) {
    /// 0x01: The attribute handle given was not valid on this server.
    invalid_handle = 0x01,
    /// 0x02: The attribute cannot be read.
    read_not_permitted = 0x02,
    /// 0x03: The attribute cannot be written.
    write_not_permitted = 0x03,
    /// 0x04: The attribute PDU was invalid.
    invalid_pdu = 0x04,
    /// 0x05: The attribute requires authentication before it can be read or written.
    insufficient_authentication = 0x05,
    /// 0x06: Attribute server does not support the request received from the client.
    request_not_supported = 0x06,
    /// 0x07: Offset specified was past the end of the attribute.
    invalid_offset = 0x07,
    /// 0x08: The attribute requires authorization before it can be read or written.
    insufficient_authorization = 0x08,
    /// 0x09: Too many prepare writes have been queued.
    prepare_queue_full = 0x09,
    /// 0x0A: No attribute found within the given attribute handle range.
    attribute_not_found = 0x0A,
    /// 0x0B: The attribute cannot be read using the Read Blob Request.
    attribute_not_long = 0x0B,
    /// 0x0C: The Encryption Key Size used for encrypting this link is insufficient.
    insufficient_encryption_key_size = 0x0C,
    /// 0x0D: The attribute value length is invalid for the operation.
    invalid_attribute_value_length = 0x0D,
    /// 0x0E: The attribute request that was requested has encountered an unlikely error.
    unlikely_error = 0x0E,
    /// 0x0F: The attribute requires encryption before it can be read or written.
    insufficient_encryption = 0x0F,
    /// 0x10: The attribute type is not a supported grouping attribute.
    unsupported_group_type = 0x10,
    /// 0x11: Insufficient Resources to complete the request.
    insufficient_resources = 0x11,
    /// 0x12: The server requests the client to rediscover the database.
    database_out_of_sync = 0x12,
    /// 0x13: The attribute parameter value was not allowed.
    value_not_allowed = 0x13,
    _,

    /// Returns true if this error code falls into the Application Error range (0x80..0x9F).
    pub inline fn isApplicationError(self: AttErrorCode) bool {
        const val = @intFromEnum(self);
        return val >= 0x80 and val <= 0x9F;
    }

    /// Returns true if this error code falls into Common Profile and Service Error range (0xE0..0xFF).
    pub inline fn isProfileError(self: AttErrorCode) bool {
        const val = @intFromEnum(self);
        return val >= 0xE0 and val <= 0xFF;
    }

    /// Human-readable specification name for standard ATT errors.
    pub fn getName(self: AttErrorCode) []const u8 {
        return switch (self) {
            .invalid_handle => "Invalid Handle",
            .read_not_permitted => "Read Not Permitted",
            .write_not_permitted => "Write Not Permitted",
            .invalid_pdu => "Invalid PDU",
            .insufficient_authentication => "Insufficient Authentication",
            .request_not_supported => "Request Not Supported",
            .invalid_offset => "Invalid Offset",
            .insufficient_authorization => "Insufficient Authorization",
            .prepare_queue_full => "Prepare Queue Full",
            .attribute_not_found => "Attribute Not Found",
            .attribute_not_long => "Attribute Not Long",
            .insufficient_encryption_key_size => "Insufficient Encryption Key Size",
            .invalid_attribute_value_length => "Invalid Attribute Value Length",
            .unlikely_error => "Unlikely Error",
            .insufficient_encryption => "Insufficient Encryption",
            .unsupported_group_type => "Unsupported Group Type",
            .insufficient_resources => "Insufficient Resources",
            .database_out_of_sync => "Database Out of Sync",
            .value_not_allowed => "Value Not Allowed",
            else => if (self.isApplicationError())
                "Application Error"
            else if (self.isProfileError())
                "Common Profile / Service Error"
            else
                "Reserved / Unknown Error",
        };
    }

    /// Maps an ATT error code into an idiomatic Zig error.
    pub fn toError(self: AttErrorCode) AttError {
        return switch (self) {
            .invalid_handle => error.InvalidHandle,
            .read_not_permitted => error.ReadNotPermitted,
            .write_not_permitted => error.WriteNotPermitted,
            .invalid_pdu => error.InvalidPdu,
            .insufficient_authentication => error.InsufficientAuthentication,
            .request_not_supported => error.RequestNotSupported,
            .invalid_offset => error.InvalidOffset,
            .insufficient_authorization => error.InsufficientAuthorization,
            .prepare_queue_full => error.PrepareQueueFull,
            .attribute_not_found => error.AttributeNotFound,
            .attribute_not_long => error.AttributeNotLong,
            .insufficient_encryption_key_size => error.InsufficientEncryptionKeySize,
            .invalid_attribute_value_length => error.InvalidAttributeValueLength,
            .unlikely_error => error.UnlikelyError,
            .insufficient_encryption => error.InsufficientEncryption,
            .unsupported_group_type => error.UnsupportedGroupType,
            .insufficient_resources => error.InsufficientResources,
            .database_out_of_sync => error.DatabaseOutOfSync,
            .value_not_allowed => error.ValueNotAllowed,
            _ => if (@intFromEnum(self) == 0xFD)
                error.CccdImproperlyConfigured
            else
                error.GattError,
        };
    }
};

/// Standard Attribute Protocol (ATT) Opcodes according to
/// Bluetooth Core Specification (Vol 3, Part F, Section 3.4).
pub const AttOpcode = gatt.AttOpcode;

/// Error set for ATT PDU decoding.
pub const AttError = error{
    PayloadTooShort,
    InvalidOpcode,
    InvalidLength,
    BufferTooSmall,
    MalformedUuid,
    InvalidFormat,
    InvalidHandle,
    ReadNotPermitted,
    WriteNotPermitted,
    InvalidPdu,
    InsufficientAuthentication,
    RequestNotSupported,
    InvalidOffset,
    InsufficientAuthorization,
    PrepareQueueFull,
    AttributeNotFound,
    AttributeNotLong,
    InsufficientEncryptionKeySize,
    InvalidAttributeValueLength,
    UnlikelyError,
    InsufficientEncryption,
    UnsupportedGroupType,
    InsufficientResources,
    DatabaseOutOfSync,
    ValueNotAllowed,
    CccdImproperlyConfigured,
    GattError,
    TransactionInProgress,
    TransactionTimeout,
    BearerTimedOut,
    BearerDisconnected,
    UnexpectedResponse,
    UnexpectedOpcode,
    InvalidMtu,
};

// ============================================================================
// ATT PDU Definitions
// ============================================================================

