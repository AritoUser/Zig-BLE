//! # Zig-BLE Standard Profiles
//!
//! Production-grade, zero-allocation implementations of standard Bluetooth SIG
//! profiles and industry-standard beacons:
//! - Heart Rate Profile (HRP)
//! - Battery Service (BAS)
//! - Device Information Service (DIS)
//! - Current Time Service (CTS)
//! - Health Thermometer Service (HTS)
//! - Blood Pressure Service (BLS)
//! - Human Interface Device Profile (HOGP / HID)
//! - Environmental Sensing Service (ESS)
//! - Nordic Semiconductor UART Service (NUS)
//! - Apple iBeacon & Google Eddystone

pub const heart_rate = @import("heart_rate.zig");
pub const HeartRateMeasurement = heart_rate.HeartRateMeasurement;
pub const SensorContactStatus = heart_rate.SensorContactStatus;
pub const BodySensorLocation = heart_rate.BodySensorLocation;

pub const battery = @import("battery.zig");
pub const BatteryService = battery.BatteryService;

pub const device_information = @import("device_information.zig");
pub const DeviceInformationService = device_information.DeviceInformationService;

pub const current_time = @import("current_time.zig");
pub const CurrentTimeService = current_time.CurrentTimeService;

pub const health_thermometer = @import("health_thermometer.zig");
pub const HealthThermometerService = health_thermometer.HealthThermometerService;

pub const blood_pressure = @import("blood_pressure.zig");
pub const BloodPressureService = blood_pressure.BloodPressureService;

pub const hid = @import("hid.zig");
pub const HidService = hid.HidService;

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

pub const pulse_oximeter = @import("pulse_oximeter.zig");
pub const PlxFeatures = pulse_oximeter.PlxFeatures;
pub const PlxMeasurementStatus = pulse_oximeter.PlxMeasurementStatus;
pub const PlxDeviceAndSensorStatus = pulse_oximeter.PlxDeviceAndSensorStatus;
pub const PlxSpotCheckMeasurement = pulse_oximeter.PlxSpotCheckMeasurement;
pub const PlxContinuousMeasurement = pulse_oximeter.PlxContinuousMeasurement;

pub const ftms = @import("ftms.zig");
pub const IndoorBikeData = ftms.IndoorBikeData;
pub const IndoorBikeAccumulator = ftms.IndoorBikeAccumulator;
pub const TreadmillData = ftms.TreadmillData;
pub const RowerData = ftms.RowerData;
pub const FitnessMachineControlPoint = ftms.FitnessMachineControlPoint;
pub const FitnessMachineFeature = ftms.FitnessMachineFeature;

pub const cpp = @import("cpp.zig");
pub const CyclingPowerMeasurement = cpp.CyclingPowerMeasurement;
pub const CyclingPowerFeature = cpp.CyclingPowerFeature;
pub const calculateCadenceRpm = cpp.calculateCadenceRpm;
pub const CadenceCalculator = cpp.CadenceCalculator;

pub const rscp = @import("rscp.zig");
pub const RscMeasurement = rscp.RscMeasurement;
pub const RscFeature = rscp.RscFeature;

test {
    const std = @import("std");
    std.testing.refAllDecls(@This());
    _ = heart_rate;
    _ = battery;
    _ = device_information;
    _ = current_time;
    _ = health_thermometer;
    _ = blood_pressure;
    _ = hid;
    _ = environmental;
    _ = nordic_uart;
    _ = beacon;
    _ = pulse_oximeter;
    _ = ftms;
    _ = cpp;
    _ = rscp;
}
