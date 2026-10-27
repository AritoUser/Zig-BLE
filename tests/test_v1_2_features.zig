//! # Zig-BLE Milestone v1.2.0: Fitness, Ergometer & Health Suite Test Suite
//!
//! Comprehensive verification of:
//! - Pulse Oximeter Profile (PLXP 0x1822)
//! - Fitness Machine Profile (FTMS 0x1826)
//! - Cycling Power Profile (CPP 0x1818)
//! - Running Speed and Cadence Profile (RSCP 0x1814)

const std = @import("std");
const Zig_BLE = @import("Zig_BLE");

const Sfloat = Zig_BLE.Sfloat;
const pulse_oximeter = Zig_BLE.pulse_oximeter;
const PlxSpotCheckMeasurement = Zig_BLE.PlxSpotCheckMeasurement;
const PlxContinuousMeasurement = Zig_BLE.PlxContinuousMeasurement;
const PlxFeatures = Zig_BLE.PlxFeatures;
const PlxDeviceAndSensorStatus = Zig_BLE.PlxDeviceAndSensorStatus;

const ftms = Zig_BLE.ftms;
const IndoorBikeData = Zig_BLE.IndoorBikeData;
const IndoorBikeAccumulator = Zig_BLE.IndoorBikeAccumulator;
const TreadmillData = Zig_BLE.TreadmillData;
const RowerData = Zig_BLE.RowerData;
const FitnessMachineControlPoint = Zig_BLE.FitnessMachineControlPoint;
const FitnessMachineFeature = Zig_BLE.FitnessMachineFeature;

const cpp = Zig_BLE.cpp;
const CyclingPowerMeasurement = Zig_BLE.CyclingPowerMeasurement;
const CyclingPowerFeature = Zig_BLE.CyclingPowerFeature;
const calculateCadenceRpm = Zig_BLE.calculateCadenceRpm;
const CadenceCalculator = Zig_BLE.CadenceCalculator;

const rscp = Zig_BLE.rscp;
const RscMeasurement = Zig_BLE.RscMeasurement;
const RscFeature = Zig_BLE.RscFeature;

// ============================================================================
// 1. Pulse Oximeter Profile (PLXP) Tests
// ============================================================================

test "v1.2 PLXP: SFLOAT spot-check measurement and special NaN filtering" {
    // Normal measurement: SpO2 = 98.0%, PR = 72.0 bpm
    const normal_spo2 = Sfloat.fromFloat(98.0);
    const normal_pr = Sfloat.fromFloat(72.0);

    const normal_m = PlxSpotCheckMeasurement{
        .spo2 = normal_spo2,
        .pulse_rate = normal_pr,
    };
    try std.testing.expectEqual(@as(?f32, 98.0), normal_m.spo2Percent());
    try std.testing.expectEqual(@as(?f32, 72.0), normal_m.pulseRateBpm());

    // Sensor disconnected / NaN measurement: SpO2 = NaN (0x07FF), PR = NRes (0x0800)
    const nan_m = PlxSpotCheckMeasurement{
        .spo2 = Sfloat.nan,
        .pulse_rate = Sfloat.not_at_this_resolution,
    };
    try std.testing.expect(nan_m.spo2.isNan());
    try std.testing.expect(nan_m.pulse_rate.isNRes());
    try std.testing.expectEqual(@as(?f32, null), nan_m.spo2Percent());
    try std.testing.expectEqual(@as(?f32, null), nan_m.pulseRateBpm());
}

test "v1.2 PLXP: 24-bit device and sensor status bitcast roundtrip" {
    const status = PlxDeviceAndSensorStatus{
        .equipment_malfunction = true,
        .low_perfusion = true,
        .sensor_disconnected = true,
    };
    const raw_bits = status.toInt();
    const reconstructed = PlxDeviceAndSensorStatus.fromInt(raw_bits);

    try std.testing.expect(reconstructed.equipment_malfunction);
    try std.testing.expect(reconstructed.low_perfusion);
    try std.testing.expect(reconstructed.sensor_disconnected);
    try std.testing.expect(!reconstructed.sensor_displaced);
}

test "v1.2 PLXP: Spot-check measurement payload too short" {
    const truncated_buf = [_]u8{ 0x00, 0x62, 0x00 }; // only 3 bytes (needs at least 5)
    try std.testing.expectError(error.PayloadTooShort, PlxSpotCheckMeasurement.parse(&truncated_buf));
}

test "v1.2 PLXP: Forward-compatibility ignores trailing vendor bytes" {
    var raw = [_]u8{
        0x00, // flags: only normal SpO2 and PR
        0x62, 0x00, // SpO2: 98%
        0x48, 0x00, // PR: 72 bpm
        0xDE, 0xAD, 0xBE, 0xEF, // Trailing vendor-specific bytes
    };
    const m = try PlxSpotCheckMeasurement.parse(&raw);
    try std.testing.expectEqual(@as(?f32, 98.0), m.spo2Percent());
    try std.testing.expectEqual(@as(?f32, 72.0), m.pulseRateBpm());
}

// ============================================================================
// 2. Fitness Machine Profile (FTMS) Tests
// ============================================================================

test "v1.2 FTMS: Inverted Bit 0 Speed omission and offset preservation" {
    // When Bit 0 is 1 (More Data), Instantaneous Speed is absent.
    // If Cadence is present (Bit 2 = 1), Cadence must start immediately at offset 2!
    // Flags: 0x0001 (Speed absent) | 0x0004 (Cadence present) = 0x0005
    // Cadence: 92.5 RPM -> raw = 185 = 0x00B9
    const raw = [_]u8{
        0x05, 0x00, // flags
        0xB9, 0x00, // cadence
    };

    const data = try IndoorBikeData.parse(&raw);
    try std.testing.expect(data.instantaneous_speed_raw == null);
    try std.testing.expectEqual(@as(?u16, 185), data.instantaneous_cadence_raw);
    try std.testing.expectEqual(@as(?f32, 92.5), data.cadenceRpm());
}

test "v1.2 FTMS: u24 Total Distance maximum boundary test" {
    // Distance = 16,777,215 meters (0xFFFFFF)
    const max_u24: u24 = 0xFFFFFF;
    const original = IndoorBikeData{
        .instantaneous_speed_raw = 3500, // 35.00 km/h
        .total_distance_meters = max_u24,
    };

    var buf: [32]u8 = undefined;
    const written = try original.encode(&buf);
    const parsed = try IndoorBikeData.parse(written);

    try std.testing.expectEqual(max_u24, parsed.total_distance_meters.?);
    try std.testing.expectEqual(@as(?f32, 35.0), parsed.speedKmh());
}

test "v1.2 FTMS: IndoorBikeAccumulator state merge over multiple fragments" {
    var acc = IndoorBikeAccumulator{};

    // Fragment 1: Speed (34.50 km/h), Heart Rate (145 bpm)
    acc.update(.{
        .instantaneous_speed_raw = 3450,
        .heart_rate_bpm = 145,
    });

    // Fragment 2: Cadence (88.0 RPM), Power (260 W), Speed omitted (Bit 0 = 1)
    acc.update(.{
        .instantaneous_cadence_raw = 176,
        .instantaneous_power_watts = 260,
    });

    // Fragment 3: Elapsed Time (1250 s), Total Distance (12400 m)
    acc.update(.{
        .elapsed_time_seconds = 1250,
        .total_distance_meters = 12400,
    });

    const full_state = acc.get();
    try std.testing.expectEqual(@as(?f32, 34.50), full_state.speedKmh());
    try std.testing.expectEqual(@as(?u8, 145), full_state.heart_rate_bpm);
    try std.testing.expectEqual(@as(?f32, 88.0), full_state.cadenceRpm());
    try std.testing.expectEqual(@as(?i16, 260), full_state.powerWatts());
    try std.testing.expectEqual(@as(?u16, 1250), full_state.elapsed_time_seconds);
    try std.testing.expectEqual(@as(?u24, 12400), full_state.total_distance_meters);
}

test "v1.2 FTMS: Control Point ERG Mode 0x05 and Simulation Mode 0x11 (Zwift/KICKR)" {
    var buf: [16]u8 = undefined;

    // ERG Mode: 300 Watts Target
    const erg_req = FitnessMachineControlPoint.Request{ .set_target_power = 300 };
    const erg_bytes = try erg_req.encode(&buf);
    try std.testing.expectEqual(@as(u8, 0x05), erg_bytes[0]);
    try std.testing.expectEqual(@as(i16, 300), std.mem.readInt(i16, erg_bytes[1..3], .little));

    // Simulation Mode: Wind -1.5 m/s (headwind), Grade +10.25%, Crr 0.0033, Cw 0.45 kg/m
    const sim_params = FitnessMachineControlPoint.IndoorBikeSimulationParams{
        .wind_speed_raw = -1500, // -1.5 * 1000
        .grade_raw = 1025, // 10.25 * 100
        .crr_raw = 33, // 0.0033 * 10000
        .cw_raw = 45, // 0.45 * 100
    };
    const sim_req = FitnessMachineControlPoint.Request{ .set_indoor_bike_simulation_parameters = sim_params };
    const sim_bytes = try sim_req.encode(&buf);

    try std.testing.expectEqual(@as(usize, 7), sim_bytes.len);
    try std.testing.expectEqual(@as(u8, 0x11), sim_bytes[0]);
    try std.testing.expectEqual(@as(i16, -1500), std.mem.readInt(i16, sim_bytes[1..3], .little));
    try std.testing.expectEqual(@as(i16, 1025), std.mem.readInt(i16, sim_bytes[3..5], .little));
    try std.testing.expectEqual(@as(u8, 33), sim_bytes[5]);
    try std.testing.expectEqual(@as(u8, 45), sim_bytes[6]);
}

test "v1.2 FTMS: Control Point response parsing and error result codes" {
    // Response to 0x05 (Target Power), Result: Control Not Permitted (0x05)
    const raw_err = [_]u8{ 0x80, 0x05, 0x05 };
    const resp = try FitnessMachineControlPoint.Response.parse(&raw_err);
    try std.testing.expect(!resp.isSuccess());
    try std.testing.expectEqual(FitnessMachineControlPoint.OpCode.set_target_power, resp.request_op_code);
    try std.testing.expectEqual(FitnessMachineControlPoint.ResultCode.control_not_permitted, resp.result_code);
}

test "v1.2 FTMS: Treadmill and Rower data parsing" {
    // Treadmill: speed present (bit 0 = 0), distance present (bit 2 = 1) -> flags = 0x0004
    // Speed: 10.00 km/h (1000 = 0x03E8), Distance: 3200 m (0x000C80)
    const tm_raw = [_]u8{
        0x04, 0x00, // flags
        0xE8, 0x03, // 10.00 km/h
        0x80, 0x0C, 0x00, // 3200 m
    };
    const tm = try TreadmillData.parse(&tm_raw);
    try std.testing.expectEqual(@as(?f32, 10.0), tm.speedKmh());
    try std.testing.expectEqual(@as(?u24, 3200), tm.total_distance_meters);

    // Rower: stroke present (bit 0 = 0), power present (bit 5 = 1) -> flags = 0x0020
    // Stroke Rate: 26 SPM (raw = 52 = 0x34), Stroke Count: 540 (0x021C), Power: 220 W (0x00DC)
    const rower_raw = [_]u8{
        0x20, 0x00, // flags
        0x34, 0x1C, 0x02, // stroke rate 52, count 540
        0xDC, 0x00, // power 220 W
    };
    const rower = try RowerData.parse(&rower_raw);
    try std.testing.expectEqual(@as(?f32, 26.0), rower.strokeRateSpm());
    try std.testing.expectEqual(@as(?u16, 540), rower.stroke_count);
    try std.testing.expectEqual(@as(?i16, 220), rower.instantaneous_power_watts);
}

// ============================================================================
// 3. Cycling Power Profile (CPP) Tests
// ============================================================================

test "v1.2 CPP: Cycling Power Measurement with pedal balance and torque" {
    // Flags: balance (0x0001) | ref left (0x0002) | torque (0x0004) = 0x0007
    // Power: 240 W (0x00F0)
    // Balance: 49.5% Left (99 = 0x63 | 0x80 = 0xE3)
    // Torque: 64 Nm (2048 = 0x0800, 2048 / 32 = 64)
    const raw = [_]u8{
        0x07, 0x00, // flags
        0xF0, 0x00, // 240 W
        0xE3, // 49.5% Left
        0x00, 0x08, // 64 Nm
    };

    const m = try CyclingPowerMeasurement.parse(&raw);
    try std.testing.expectEqual(@as(i16, 240), m.powerWatts());
    try std.testing.expect(m.isPedalBalanceReferenceLeft());
    try std.testing.expectEqual(@as(?f32, 49.5), m.pedalPowerBalancePercent());
    try std.testing.expectEqual(@as(?f32, 64.0), m.accumulatedTorqueNm());
}

test "v1.2 CPP: 64-second 1/1024s timestamp rollover wrapping subtraction" {
    // Testing wrapping across u16 boundary 65535 -> 0
    // Event 1: at timer tick 65200, revs = 500
    // Event 2: at timer tick 347 (after wrap), revs = 501
    // Delta time = 347 -% 65200 = 347 + (65536 - 65200) = 347 + 336 = 683 ticks (approx 90 RPM)
    const rpm = calculateCadenceRpm(500, 65200, 501, 347).?;
    try std.testing.expect(rpm > 89.8 and rpm < 90.2);

    // Coasting / Freewheeling (revs difference is 0)
    const coasting = calculateCadenceRpm(500, 65200, 500, 347).?;
    try std.testing.expectEqual(@as(f32, 0.0), coasting);
}

test "v1.2 CPP: CadenceCalculator continuous state update" {
    var calc = CadenceCalculator{};

    // First reading: sets baseline
    const r1 = calc.update(.{
        .instantaneous_power = 220,
        .cumulative_crank_revs = 100,
        .last_crank_event_time = 5000,
    });
    try std.testing.expect(r1 == null);

    // Second reading: 1 rev in 683 ticks (approx 90 RPM)
    const r2 = calc.update(.{
        .instantaneous_power = 225,
        .cumulative_crank_revs = 101,
        .last_crank_event_time = 5683,
    }).?;
    try std.testing.expect(r2 > 89.8 and r2 < 90.2);
}

// ============================================================================
// 4. Running Speed and Cadence Profile (RSCP) Tests
// ============================================================================

test "v1.2 RSCP: Running Speed, Stride, Cadence and Status" {
    // Flags: stride present (0x01) | total distance present (0x02) | running (0x04) = 0x07
    // Speed: 4.0 m/s (4.0 * 256 = 1024 = 0x0400) -> 14.4 km/h
    // Cadence: 175 RPM = 0xAF
    // Stride: 1.25 m (125 cm = 0x007D)
    // Total Distance: 10,000.0 m (100,000 dm = 0x000186A0)
    const raw = [_]u8{
        0x07, // flags
        0x00, 0x04, // 4.0 m/s
        0xAF, // 175 RPM
        0x7D, 0x00, // 1.25 m
        0xA0, 0x86, 0x01, 0x00, // 100,000 dm
    };

    const rsc = try RscMeasurement.parse(&raw);
    try std.testing.expect(rsc.is_running);
    try std.testing.expectEqual(@as(f32, 4.0), rsc.speedMetersPerSecond());
    try std.testing.expectApproxEqAbs(@as(f32, 14.4), rsc.speedKilometersPerHour(), 0.001);
    try std.testing.expectEqual(@as(u8, 175), rsc.cadenceRpm());
    try std.testing.expectEqual(@as(?f32, 1.25), rsc.strideLengthMeters());
    try std.testing.expectEqual(@as(?f32, 10000.0), rsc.totalDistanceMeters());
}
