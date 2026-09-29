//! HCI (Host Controller Interface) constants and wire-protocol definitions.
//! Strictly adhering to Bluetooth Core Specification v5.4 & v6.0, Vol 4, Part E.

const std = @import("std");

/// Linux Bluetooth socket family and protocol identifiers.
pub const AF_BLUETOOTH: u16 = 31;
pub const BTPROTO_HCI: u32 = 1;

/// HCI Socket Channels (Kernel-level binding modes)
pub const HCI_CHANNEL_RAW: u16 = 0;
pub const HCI_CHANNEL_USER: u16 = 1;
pub const HCI_CHANNEL_MONITOR: u16 = 2;
pub const HCI_CHANNEL_CONTROL: u16 = 3;
pub const HCI_CHANNEL_LOGGING: u16 = 4;

/// Socket option for setting HCI event/packet filters (SOL_HCI = 0, HCI_FILTER = 2)
pub const SOL_HCI: u32 = 0;
pub const HCI_FILTER: u32 = 2;

/// Linux Kernel sockaddr_hci representation
pub const sockaddr_hci = extern struct {
    hci_family: u16 = AF_BLUETOOTH,
    hci_dev: u16 = 0, // HCI device index (0 for hci0, 1 for hci1, etc.)
    hci_channel: u16 = HCI_CHANNEL_RAW,
};

/// HCI Packet Indicator Types (Byte 0 on raw HCI transport)
pub const PacketType = enum(u8) {
    command = 0x01,
    acl_data = 0x02,
    sco_data = 0x03,
    event = 0x04,
    iso_data = 0x05,
    _,
};

/// HCI Opcode Group Fields (OGF)
pub const Ogf = struct {
    pub const link_control: u8 = 0x01;
    pub const link_policy: u8 = 0x02;
    pub const host_controller_baseband: u8 = 0x03;
    pub const informational_parameters: u8 = 0x04;
    pub const status_parameters: u8 = 0x05;
    pub const testing: u8 = 0x06;
    pub const le_controller: u8 = 0x08;
    pub const vendor_specific: u8 = 0x3F;
};

/// Helper to compose a 16-bit HCI Opcode from OGF (6 bits) and OCF (10 bits).
pub inline fn makeOpcode(ogf: u8, ocf: u10) u16 {
    return (@as(u16, ogf) << 10) | @as(u16, ocf);
}

/// Helper to decompose an Opcode into OGF and OCF.
pub inline fn getOgf(opcode: u16) u8 {
    return @intCast(opcode >> 10);
}

pub inline fn getOcf(opcode: u16) u10 {
    return @truncate(opcode & 0x03FF);
}

/// Common HCI Command Opcodes
pub const Opcode = struct {
    // Host Controller & Baseband (OGF 0x03)
    pub const reset: u16 = makeOpcode(Ogf.host_controller_baseband, 0x0003);
    pub const set_event_mask: u16 = makeOpcode(Ogf.host_controller_baseband, 0x0001);
    pub const set_event_filter: u16 = makeOpcode(Ogf.host_controller_baseband, 0x0005);
    pub const write_le_host_support: u16 = makeOpcode(Ogf.host_controller_baseband, 0x006D);

    // Informational Parameters (OGF 0x04)
    pub const read_local_version_information: u16 = makeOpcode(Ogf.informational_parameters, 0x0001);
    pub const read_local_supported_commands: u16 = makeOpcode(Ogf.informational_parameters, 0x0002);
    pub const read_local_supported_features: u16 = makeOpcode(Ogf.informational_parameters, 0x0003);
    pub const read_bd_addr: u16 = makeOpcode(Ogf.informational_parameters, 0x0009);

    // LE Controller Commands (OGF 0x08)
    pub const le_set_event_mask: u16 = makeOpcode(Ogf.le_controller, 0x0001);
    pub const le_read_buffer_size: u16 = makeOpcode(Ogf.le_controller, 0x0002);
    pub const le_read_local_supported_features: u16 = makeOpcode(Ogf.le_controller, 0x0003);
    pub const le_set_random_address: u16 = makeOpcode(Ogf.le_controller, 0x0005);
    pub const le_set_advertising_parameters: u16 = makeOpcode(Ogf.le_controller, 0x0006);
    pub const le_read_advertising_channel_tx_power: u16 = makeOpcode(Ogf.le_controller, 0x0007);
    pub const le_set_advertising_data: u16 = makeOpcode(Ogf.le_controller, 0x0008);
    pub const le_set_scan_response_data: u16 = makeOpcode(Ogf.le_controller, 0x0009);
    pub const le_set_advertise_enable: u16 = makeOpcode(Ogf.le_controller, 0x000A);
    pub const le_set_scan_parameters: u16 = makeOpcode(Ogf.le_controller, 0x000B);
    pub const le_set_scan_enable: u16 = makeOpcode(Ogf.le_controller, 0x000C);
    pub const le_create_connection: u16 = makeOpcode(Ogf.le_controller, 0x000D);
    pub const le_create_connection_cancel: u16 = makeOpcode(Ogf.le_controller, 0x000E);
    pub const le_read_filter_accept_list_size: u16 = makeOpcode(Ogf.le_controller, 0x000F);
    pub const le_clear_filter_accept_list: u16 = makeOpcode(Ogf.le_controller, 0x0010);
    pub const le_add_device_to_filter_accept_list: u16 = makeOpcode(Ogf.le_controller, 0x0011);
    pub const le_remove_device_from_filter_accept_list: u16 = makeOpcode(Ogf.le_controller, 0x0012);
    pub const le_set_data_length: u16 = makeOpcode(Ogf.le_controller, 0x0022);
    pub const le_read_suggested_default_data_length: u16 = makeOpcode(Ogf.le_controller, 0x0023);
    pub const le_write_suggested_default_data_length: u16 = makeOpcode(Ogf.le_controller, 0x0024);
    pub const le_read_local_p256_public_key: u16 = makeOpcode(Ogf.le_controller, 0x0025);
    pub const le_generate_dhkey: u16 = makeOpcode(Ogf.le_controller, 0x0026);
    pub const le_read_maximum_data_length: u16 = makeOpcode(Ogf.le_controller, 0x002F);
    pub const le_read_phy: u16 = makeOpcode(Ogf.le_controller, 0x0030);
    pub const le_set_default_phy: u16 = makeOpcode(Ogf.le_controller, 0x0031);
    pub const le_set_phy: u16 = makeOpcode(Ogf.le_controller, 0x0032);
    pub const le_set_ext_advertising_parameters: u16 = makeOpcode(Ogf.le_controller, 0x0036);
    pub const le_set_ext_advertising_data: u16 = makeOpcode(Ogf.le_controller, 0x0037);
    pub const le_set_ext_scan_response_data: u16 = makeOpcode(Ogf.le_controller, 0x0038);
    pub const le_set_ext_advertise_enable: u16 = makeOpcode(Ogf.le_controller, 0x0039);
    pub const le_set_periodic_advertising_parameters: u16 = makeOpcode(Ogf.le_controller, 0x003E);
    pub const le_set_periodic_advertising_data: u16 = makeOpcode(Ogf.le_controller, 0x003F);
    pub const le_set_periodic_advertising_enable: u16 = makeOpcode(Ogf.le_controller, 0x0040);
    pub const le_set_ext_scan_parameters: u16 = makeOpcode(Ogf.le_controller, 0x0041);
    pub const le_set_ext_scan_enable: u16 = makeOpcode(Ogf.le_controller, 0x0042);
    pub const le_extended_create_connection: u16 = makeOpcode(Ogf.le_controller, 0x0043);
    pub const le_periodic_advertising_create_sync: u16 = makeOpcode(Ogf.le_controller, 0x0044);
    pub const le_periodic_advertising_terminate_sync: u16 = makeOpcode(Ogf.le_controller, 0x0046);
    pub const le_generate_dhkey_v2: u16 = makeOpcode(Ogf.le_controller, 0x005E);
};

/// HCI Event Codes
pub const EventCode = struct {
    pub const inquiry_complete: u8 = 0x01;
    pub const inquiry_result: u8 = 0x02;
    pub const connection_complete: u8 = 0x03;
    pub const connection_request: u8 = 0x04;
    pub const disconnection_complete: u8 = 0x05;
    pub const authentication_complete: u8 = 0x06;
    pub const encryption_change: u8 = 0x08;
    pub const command_complete: u8 = 0x0E;
    pub const command_status: u8 = 0x0F;
    pub const hardware_error: u8 = 0x10;
    pub const number_of_completed_packets: u8 = 0x13;
    pub const data_buffer_overflow: u8 = 0x1A;
    pub const le_meta_event: u8 = 0x3E;
};

/// Subevents for HCI_LE_Meta_Event (EventCode 0x3E)
pub const LeSubevent = struct {
    pub const connection_complete: u8 = 0x01;
    pub const advertising_report: u8 = 0x02;
    pub const connection_update_complete: u8 = 0x03;
    pub const read_remote_features_complete: u8 = 0x04;
    pub const long_term_key_request: u8 = 0x05;
    pub const remote_connection_parameter_request: u8 = 0x06;
    pub const data_length_change: u8 = 0x07;
    pub const read_local_p256_public_key_complete: u8 = 0x08;
    pub const generate_dhkey_complete: u8 = 0x09;
    pub const phy_update_complete: u8 = 0x0C;
    pub const extended_advertising_report: u8 = 0x0D;
    pub const periodic_advertising_sync_established: u8 = 0x0E;
    pub const periodic_advertising_report: u8 = 0x0F;
    pub const periodic_advertising_sync_lost: u8 = 0x10;
    pub const scan_timeout: u8 = 0x11;
    pub const advertising_set_terminated: u8 = 0x12;
    pub const scan_request_received: u8 = 0x13;
    pub const channel_selection_algorithm: u8 = 0x14;
};

/// Standard HCI Status Codes
pub const Status = enum(u8) {
    success = 0x00,
    unknown_hci_command = 0x01,
    unknown_connection_identifier = 0x02,
    hardware_failure = 0x03,
    page_timeout = 0x04,
    authentication_failure = 0x05,
    pin_or_key_missing = 0x06,
    memory_capacity_exceeded = 0x07,
    connection_timeout = 0x08,
    connection_limit_exceeded = 0x09,
    command_disallowed = 0x0C,
    unsupported_feature = 0x11,
    invalid_hci_command_parameters = 0x12,
    remote_user_terminated_connection = 0x13,
    unsupported_remote_feature = 0x1A,
    controller_busy = 0x3A,
    unacceptable_connection_parameters = 0x3B,
    directed_advertising_timeout = 0x3C,
    connection_failed_to_be_established = 0x3E,
    _,
};

test "makeOpcode and opcode extraction" {
    const opcode = makeOpcode(Ogf.le_controller, 0x000B); // LE Set Scan Parameters
    try std.testing.expectEqual(@as(u16, 0x200B), opcode);
    try std.testing.expectEqual(Ogf.le_controller, getOgf(opcode));
    try std.testing.expectEqual(@as(u10, 0x000B), getOcf(opcode));

    const reset_op = Opcode.reset;
    try std.testing.expectEqual(@as(u16, 0x0C03), reset_op);
    try std.testing.expectEqual(Ogf.host_controller_baseband, getOgf(reset_op));
}
