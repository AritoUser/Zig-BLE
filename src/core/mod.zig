//! Zig-BLE Core: Platform-independent BLE domain logic conforming to the Bluetooth Core Specification.
const std = @import("std");

pub const types = @import("types.zig");
pub const assigned_numbers = @import("assigned_numbers.zig");
pub const gatt = @import("gatt.zig");
pub const advertising = @import("advertising.zig");
pub const format = @import("format.zig");
pub const att = @import("att.zig");

// Re-export primary types for ergonomic access
pub const Address = types.Address;
pub const AddressType = types.AddressType;
pub const DeviceAddress = types.DeviceAddress;
pub const UUID = types.UUID;

pub const Services = assigned_numbers.Services;
pub const Characteristics = assigned_numbers.Characteristics;
pub const Descriptors = assigned_numbers.Descriptors;
pub const CompanyId = assigned_numbers.CompanyId;
pub const Appearance = assigned_numbers.Appearance;
pub const Units = assigned_numbers.Units;

pub const CharacteristicProperties = gatt.CharacteristicProperties;
pub const CharacteristicProps = gatt.CharacteristicProps;
pub const Cccd = gatt.Cccd;
pub const ServiceType = gatt.ServiceType;
pub const WriteType = gatt.WriteType;
pub const AttOpcode = gatt.AttOpcode;
pub const ParseError = gatt.ParseError;
pub const NotificationData = gatt.NotificationData;
pub const parseNotification = gatt.parseNotification;

pub const AttErrorCode = att.AttErrorCode;
pub const AttPdu = att.AttPdu;
pub const AttError = att.AttError;

pub const AdType = advertising.AdType;
pub const AdvertisingFlags = advertising.AdvertisingFlags;
pub const ManufacturerData = advertising.ManufacturerData;
pub const ServiceData16 = advertising.ServiceData16;
pub const ServiceData32 = advertising.ServiceData32;
pub const ServiceData128 = advertising.ServiceData128;
pub const ServiceUuids16Iterator = advertising.ServiceUuids16Iterator;
pub const ServiceUuids32Iterator = advertising.ServiceUuids32Iterator;
pub const ServiceUuids128Iterator = advertising.ServiceUuids128Iterator;
pub const AdStructure = advertising.AdStructure;
pub const AdIterator = advertising.AdIterator;
pub const AdvertisingReport = advertising.AdvertisingReport;
pub const PhyType = advertising.PhyType;
pub const SecondaryChannel = advertising.SecondaryChannel;

pub const Sfloat = format.Sfloat;
pub const Float32 = format.Float32;
pub const FormatType = format.FormatType;
pub const CharacteristicPresentationFormat = format.CharacteristicPresentationFormat;
pub const serialize = format.serialize;
pub const deserialize = format.deserialize;

pub const transfers = @import("transfers.zig");
pub const LongWriteIterator = transfers.LongWriteIterator;
pub const LongReadReassembler = transfers.LongReadReassembler;
pub const ServerPrepareWriteQueue = transfers.ServerPrepareWriteQueue;
pub const QueuedWriteChunk = transfers.QueuedWriteChunk;

test {
    std.testing.refAllDecls(@This());
    _ = types;
    _ = assigned_numbers;
    _ = gatt;
    _ = advertising;
    _ = format;
    _ = att;
    _ = transfers;
}
