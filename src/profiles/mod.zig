//! # Zig-BLE Standard Profiles
//!
//! Production-grade, zero-allocation implementations of standard Bluetooth SIG
//! profiles and industry-standard beacons:
//! - Heart Rate Profile (HRP)
//! - Battery Service (BAS)
//! - Environmental Sensing Service (ESS)
//! - Nordic Semiconductor UART Service (NUS)
//! - Apple iBeacon & Google Eddystone

pub const heart_rate = @import("heart_rate.zig");
pub const HeartRateMeasurement = heart_rate.HeartRateMeasurement;
pub const SensorContactStatus = heart_rate.SensorContactStatus;
pub const BodySensorLocation = heart_rate.BodySensorLocation;

pub const battery = @import("battery.zig");
pub const BatteryService = battery.BatteryService;

pub const environmental = @import("environmental.zig");
pub const EnvironmentalSensing = environmental.EnvironmentalSensing;

pub const nordic_uart = @import("nordic_uart.zig");
pub const NordicUart = nordic_uart.NordicUart;

pub const beacon = @import("beacon.zig");
pub const Beacon = beacon;
pub const IBeacon = beacon.IBeacon;
pub const AppleIBeacon = beacon.AppleIBeacon;
pub const Eddystone = beacon.Eddystone;
pub const EddystoneUrl = beacon.EddystoneUrl;
pub const EddystoneUid = beacon.EddystoneUid;
pub const EddystoneTlm = beacon.EddystoneTlm;

test {
    const std = @import("std");
    std.testing.refAllDecls(@This());
    _ = heart_rate;
    _ = battery;
    _ = environmental;
    _ = nordic_uart;
    _ = beacon;
}
