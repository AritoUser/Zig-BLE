const std = @import("std");
const types = @import("types.zig");
const UUID = types.UUID;

/// Bluetooth SIG Assigned Numbers for standardized GATT Services (GSS).
pub const Services = struct {
    pub const generic_access = UUID.from16(0x1800);
    pub const generic_attribute = UUID.from16(0x1801);
    pub const immediate_alert = UUID.from16(0x1802);
    pub const link_loss = UUID.from16(0x1803);
    pub const tx_power = UUID.from16(0x1804);
    pub const current_time = UUID.from16(0x1805);
    pub const reference_time_update = UUID.from16(0x1806);
    pub const next_dst_change = UUID.from16(0x1807);
    pub const glucose = UUID.from16(0x1808);
    pub const health_thermometer = UUID.from16(0x1809);
    pub const device_information = UUID.from16(0x180A);
    pub const heart_rate = UUID.from16(0x180D);
    pub const phone_alert_status = UUID.from16(0x180E);
    pub const battery_service = UUID.from16(0x180F);
    pub const blood_pressure = UUID.from16(0x1810);
    pub const alert_notification = UUID.from16(0x1811);
    pub const human_interface_device = UUID.from16(0x1812);
    pub const scan_parameters = UUID.from16(0x1813);
    pub const running_speed_and_cadence = UUID.from16(0x1814);
    pub const cycling_speed_and_cadence = UUID.from16(0x1816);
    pub const cycling_power = UUID.from16(0x1818);
    pub const location_and_navigation = UUID.from16(0x1819);
    pub const environmental_sensing = UUID.from16(0x181A);
    pub const body_composition = UUID.from16(0x181B);
    pub const user_data = UUID.from16(0x181C);
    pub const weight_scale = UUID.from16(0x181D);
    pub const pulse_oximeter = UUID.from16(0x1822);
    pub const internet_protocol_support = UUID.from16(0x1820);

    /// Known vendor services (e.g. Nordic UART Service).
    pub const nordic_uart = UUID{
        .bytes = .{
            0x6e, 0x40, 0x00, 0x01,
            0xb5, 0xa3,
            0xf3, 0x93,
            0xe0, 0xa9,
            0xe5, 0x0e, 0x24, 0xdc, 0xca, 0x9e,
        },
    };
    const service_lut = initServiceLut();

    fn initServiceLut() [35]?[]const u8 {
        var lut = [_]?[]const u8{null} ** 35;
        lut[0x1800 - 0x1800] = "Generic Access";
        lut[0x1801 - 0x1800] = "Generic Attribute";
        lut[0x1802 - 0x1800] = "Immediate Alert";
        lut[0x1803 - 0x1800] = "Link Loss";
        lut[0x1804 - 0x1800] = "Tx Power";
        lut[0x1805 - 0x1800] = "Current Time";
        lut[0x1806 - 0x1800] = "Reference Time Update";
        lut[0x1807 - 0x1800] = "Next DST Change";
        lut[0x1808 - 0x1800] = "Glucose";
        lut[0x1809 - 0x1800] = "Health Thermometer";
        lut[0x180A - 0x1800] = "Device Information";
        lut[0x180D - 0x1800] = "Heart Rate";
        lut[0x180E - 0x1800] = "Phone Alert Status";
        lut[0x180F - 0x1800] = "Battery Service";
        lut[0x1810 - 0x1800] = "Blood Pressure";
        lut[0x1811 - 0x1800] = "Alert Notification";
        lut[0x1812 - 0x1800] = "Human Interface Device";
        lut[0x1813 - 0x1800] = "Scan Parameters";
        lut[0x1814 - 0x1800] = "Running Speed and Cadence";
        lut[0x1816 - 0x1800] = "Cycling Speed and Cadence";
        lut[0x1818 - 0x1800] = "Cycling Power";
        lut[0x1819 - 0x1800] = "Location and Navigation";
        lut[0x181A - 0x1800] = "Environmental Sensing";
        lut[0x181B - 0x1800] = "Body Composition";
        lut[0x181C - 0x1800] = "User Data";
        lut[0x181D - 0x1800] = "Weight Scale";
        lut[0x1820 - 0x1800] = "Internet Protocol Support";
        lut[0x1822 - 0x1800] = "Pulse Oximeter";
        return lut;
    }

    /// Returns the human-readable name of a standardized service.
    pub inline fn getName(uuid: UUID) ?[]const u8 {
        if (uuid.to16()) |val| {
            const idx = val -% 0x1800;
            if (idx < service_lut.len) {
                return service_lut[idx];
            }
            return null;
        }
        if (uuid.eql(nordic_uart)) return "Nordic UART Service";
        return null;
    }
};

/// Bluetooth SIG Assigned Numbers for standardized GATT Characteristics.
pub const Characteristics = struct {
    pub const device_name = UUID.from16(0x2A00);
    pub const appearance = UUID.from16(0x2A01);
    pub const peripheral_privacy_flag = UUID.from16(0x2A02);
    pub const reconnection_address = UUID.from16(0x2A03);
    pub const peripheral_preferred_connection_parameters = UUID.from16(0x2A04);
    pub const service_changed = UUID.from16(0x2A05);
    pub const alert_level = UUID.from16(0x2A06);
    pub const tx_power_level = UUID.from16(0x2A07);
    pub const temperature_measurement = UUID.from16(0x2A1C);
    pub const battery_level = UUID.from16(0x2A19);
    pub const system_id = UUID.from16(0x2A23);
    pub const model_number_string = UUID.from16(0x2A24);
    pub const serial_number_string = UUID.from16(0x2A25);
    pub const firmware_revision_string = UUID.from16(0x2A26);
    pub const hardware_revision_string = UUID.from16(0x2A27);
    pub const software_revision_string = UUID.from16(0x2A28);
    pub const manufacturer_name_string = UUID.from16(0x2A29);
    pub const pnp_id = UUID.from16(0x2A50);

    // Heart Rate
    pub const heart_rate_measurement = UUID.from16(0x2A37);
    pub const body_sensor_location = UUID.from16(0x2A38);
    pub const heart_rate_control_point = UUID.from16(0x2A39);

    // Nordic UART RX/TX
    pub const nordic_uart_rx = UUID{
        .bytes = .{
            0x6e, 0x40, 0x00, 0x02,
            0xb5, 0xa3,
            0xf3, 0x93,
            0xe0, 0xa9,
            0xe5, 0x0e, 0x24, 0xdc, 0xca, 0x9e,
        },
    };

    pub const nordic_uart_tx = UUID{
        .bytes = .{
            0x6e, 0x40, 0x00, 0x03,
            0xb5, 0xa3,
            0xf3, 0x93,
            0xe0, 0xa9,
            0xe5, 0x0e, 0x24, 0xdc, 0xca, 0x9e,
        },
    };

    pub fn getName(uuid: UUID) ?[]const u8 {
        if (uuid.to16()) |val| {
            return switch (val) {
                0x2A00 => "Device Name",
                0x2A01 => "Appearance",
                0x2A02 => "Peripheral Privacy Flag",
                0x2A03 => "Reconnection Address",
                0x2A04 => "Peripheral Preferred Connection Parameters",
                0x2A05 => "Service Changed",
                0x2A06 => "Alert Level",
                0x2A07 => "Tx Power Level",
                0x2A19 => "Battery Level",
                0x2A1C => "Temperature Measurement",
                0x2A23 => "System ID",
                0x2A24 => "Model Number String",
                0x2A25 => "Serial Number String",
                0x2A26 => "Firmware Revision String",
                0x2A27 => "Hardware Revision String",
                0x2A28 => "Software Revision String",
                0x2A29 => "Manufacturer Name String",
                0x2A37 => "Heart Rate Measurement",
                0x2A38 => "Body Sensor Location",
                0x2A39 => "Heart Rate Control Point",
                0x2A50 => "PnP ID",
                else => null,
            };
        }
        if (uuid.eql(nordic_uart_rx)) return "Nordic UART RX";
        if (uuid.eql(nordic_uart_tx)) return "Nordic UART TX";
        return null;
    }
};

/// Bluetooth SIG Assigned Numbers for standardized GATT Descriptors.
pub const Descriptors = struct {
    pub const characteristic_extended_properties = UUID.from16(0x2900);
    pub const characteristic_user_description = UUID.from16(0x2901); // CUDD
    pub const client_characteristic_configuration = UUID.from16(0x2902); // CCCD
    pub const server_characteristic_configuration = UUID.from16(0x2903);
    pub const characteristic_presentation_format = UUID.from16(0x2904);
    pub const characteristic_aggregate_format = UUID.from16(0x2905);
    pub const valid_range = UUID.from16(0x2906);
    pub const external_report_reference = UUID.from16(0x2907);
    pub const report_reference = UUID.from16(0x2908);
    pub const value_trigger_setting = UUID.from16(0x290A);
    pub const environmental_sensing_configuration = UUID.from16(0x290B);

    pub fn getName(uuid: UUID) ?[]const u8 {
        if (uuid.to16()) |val| {
            return switch (val) {
                0x2900 => "Characteristic Extended Properties",
                0x2901 => "Characteristic User Description (CUDD)",
                0x2902 => "Client Characteristic Configuration (CCCD)",
                0x2903 => "Server Characteristic Configuration",
                0x2904 => "Characteristic Presentation Format",
                0x2905 => "Characteristic Aggregate Format",
                0x2906 => "Valid Range",
                0x2907 => "External Report Reference",
                0x2908 => "Report Reference",
                0x290A => "Value Trigger Setting",
                0x290B => "Environmental Sensing Configuration",
                else => null,
            };
        }
        return null;
    }
};

/// Bluetooth SIG Company Identifiers (16-bit IDs in Manufacturer Specific Data).
pub const CompanyId = struct {
    pub const ericsson: u16 = 0x0000;
    pub const nokia: u16 = 0x0001;
    pub const intel: u16 = 0x0002;
    pub const ibm: u16 = 0x0003;
    pub const toshiba: u16 = 0x0004;
    pub const microsoft: u16 = 0x0006;
    pub const motorola: u16 = 0x0008;
    pub const texas_instruments: u16 = 0x000D;
    pub const broadcom: u16 = 0x000F;
    pub const qualcomm: u16 = 0x001D;
    pub const apple: u16 = 0x004C;
    pub const nordic_semiconductor: u16 = 0x0059;
    pub const samsung: u16 = 0x0075;
    pub const garmin: u16 = 0x0087;
    pub const google: u16 = 0x00E0;
    pub const sony: u16 = 0x012D;
    pub const huawei: u16 = 0x027D;
    pub const espressif: u16 = 0x02E5;
    pub const bose: u16 = 0x02FE;
    pub const xiaomi: u16 = 0x038F;

    pub fn getName(id: u16) ?[]const u8 {
        return switch (id) {
            ericsson => "Ericsson Technology Licensing",
            nokia => "Nokia Mobile Phones",
            intel => "Intel Corp.",
            ibm => "IBM Corp.",
            toshiba => "Toshiba Corp.",
            microsoft => "Microsoft",
            motorola => "Motorola",
            texas_instruments => "Texas Instruments Inc.",
            broadcom => "Broadcom Corporation",
            qualcomm => "Qualcomm",
            apple => "Apple, Inc.",
            nordic_semiconductor => "Nordic Semiconductor ASA",
            samsung => "Samsung Electronics Co. Ltd.",
            garmin => "Garmin International, Inc.",
            google => "Google",
            sony => "Sony Group Corporation",
            huawei => "Huawei Technologies Co., Ltd.",
            espressif => "Espressif Systems (Shanghai) Co., Ltd.",
            bose => "Bose Corporation",
            xiaomi => "Xiaomi Inc.",
            else => null,
        };
    }
};

/// Bluetooth SIG Appearance Categories (GATT Characteristic 0x2A01).
pub const Appearance = struct {
    pub const unknown: u16 = 0;
    pub const generic_phone: u16 = 64;
    pub const generic_computer: u16 = 128;
    pub const generic_watch: u16 = 192;
    pub const sports_watch: u16 = 193;
    pub const generic_clock: u16 = 256;
    pub const generic_display: u16 = 320;
    pub const generic_remote_control: u16 = 384;
    pub const generic_eye_glasses: u16 = 448;
    pub const generic_tag: u16 = 512;
    pub const generic_keyring: u16 = 576;
    pub const generic_media_player: u16 = 640;
    pub const generic_barcode_scanner: u16 = 704;
    pub const generic_thermometer: u16 = 768;
    pub const thermometer_ear: u16 = 769;
    pub const generic_heart_rate_sensor: u16 = 832;
    pub const heart_rate_belt: u16 = 833;
    pub const generic_blood_pressure: u16 = 896;
    pub const human_interface_device: u16 = 960;
    pub const keyboard: u16 = 961;
    pub const mouse: u16 = 962;
    pub const joystick: u16 = 963;
    pub const gamepad: u16 = 964;
    pub const generic_glucose_meter: u16 = 1024;
    pub const generic_running_walking_sensor: u16 = 1088;
    pub const generic_cycling: u16 = 1152;
    pub const generic_pulse_oximeter: u16 = 3136;
    pub const generic_weight_scale: u16 = 3200;

    /// Extracts the primary category (bits 6..15).
    pub fn getCategory(val: u16) u16 {
        return val & 0xFFC0;
    }

    /// Returns a human-readable name for known Appearance values.
    pub fn getName(val: u16) []const u8 {
        return switch (val) {
            unknown => "Unknown",
            generic_phone => "Generic Phone",
            generic_computer => "Generic Computer",
            generic_watch => "Generic Watch",
            sports_watch => "Sports Watch",
            generic_clock => "Generic Clock",
            generic_display => "Generic Display",
            generic_remote_control => "Generic Remote Control",
            generic_eye_glasses => "Generic Eye-glasses",
            generic_tag => "Generic Tag",
            generic_keyring => "Generic Keyring",
            generic_media_player => "Generic Media Player",
            generic_barcode_scanner => "Generic Barcode Scanner",
            generic_thermometer => "Generic Thermometer",
            thermometer_ear => "Ear Thermometer",
            generic_heart_rate_sensor => "Generic Heart Rate Sensor",
            heart_rate_belt => "Heart Rate Belt",
            generic_blood_pressure => "Generic Blood Pressure",
            human_interface_device => "Human Interface Device",
            keyboard => "Keyboard",
            mouse => "Mouse",
            joystick => "Joystick",
            gamepad => "Gamepad",
            generic_glucose_meter => "Generic Glucose Meter",
            generic_running_walking_sensor => "Generic Running Walking Sensor",
            generic_cycling => "Generic Cycling",
            generic_pulse_oximeter => "Generic Pulse Oximeter",
            generic_weight_scale => "Generic Weight Scale",
            else => "Other / Unknown",
        };
    }
};

// ============================================================================
// Unit Tests
// ============================================================================

test "AssignedNumbers: Services and lookup" {
    try std.testing.expectEqualStrings("Heart Rate", Services.getName(Services.heart_rate).?);
    try std.testing.expectEqualStrings("Battery Service", Services.getName(Services.battery_service).?);
    try std.testing.expectEqualStrings("Nordic UART Service", Services.getName(Services.nordic_uart).?);
    try std.testing.expect(Services.getName(UUID.from16(0x9999)) == null);
}

test "AssignedNumbers: Characteristics lookup" {
    try std.testing.expectEqualStrings("Device Name", Characteristics.getName(Characteristics.device_name).?);
    try std.testing.expectEqualStrings("Battery Level", Characteristics.getName(Characteristics.battery_level).?);
    try std.testing.expectEqualStrings("Heart Rate Measurement", Characteristics.getName(Characteristics.heart_rate_measurement).?);
}

test "AssignedNumbers: Descriptors lookup" {
    try std.testing.expectEqualStrings(
        "Client Characteristic Configuration (CCCD)",
        Descriptors.getName(Descriptors.client_characteristic_configuration).?,
    );
}

test "AssignedNumbers: CompanyId lookup" {
    try std.testing.expectEqualStrings("Apple, Inc.", CompanyId.getName(CompanyId.apple).?);
    try std.testing.expectEqualStrings("Nordic Semiconductor ASA", CompanyId.getName(CompanyId.nordic_semiconductor).?);
    try std.testing.expectEqualStrings("Espressif Systems (Shanghai) Co., Ltd.", CompanyId.getName(CompanyId.espressif).?);
    try std.testing.expect(CompanyId.getName(0xFFFF) == null);
}

test "AssignedNumbers: Appearance category and lookup" {
    try std.testing.expectEqualStrings("Sports Watch", Appearance.getName(Appearance.sports_watch));
    try std.testing.expectEqualStrings("Heart Rate Belt", Appearance.getName(Appearance.heart_rate_belt));
    try std.testing.expectEqual(Appearance.generic_watch, Appearance.getCategory(Appearance.sports_watch));
}
