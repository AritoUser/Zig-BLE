//! # Zig-BLE Raw HCI Subsystem (Zero-Daemon / Embedded Mode)
//!
//! Provides direct hardware communication with Bluetooth controllers via
//! Linux `AF_BLUETOOTH` and `BTPROTO_HCI` raw sockets, plus H4 and H5 (3-Wire) UART transports.
//!
//! ## Architectural Highlights
//! - **Zero Daemons**: Operates without `bluetoothd`, without D-Bus, and without systemd.
//! - **Zero Allocations**: Direct packet parsing slicing into stack-allocated buffers.
//! - **Sub-Microsecond Latency**: Bypasses D-Bus IPC context switches entirely.
//! - **Turnkey High-Level API**: Includes `HciController`, `AclFlowController`, `HciSocket`, `HciFilter`, `Commands`, `HciEvent`, `h4`, and `h5`.

const std = @import("std");

pub const constants = @import("constants.zig");
pub const filter = @import("filter.zig");
pub const commands = @import("commands.zig");
pub const events = @import("events.zig");
pub const socket = @import("socket.zig");
pub const controller = @import("controller.zig");
pub const h4 = @import("h4.zig");
pub const h5 = @import("h5.zig");

// Primary re-exports
pub const H4Type = h4.H4Type;
pub const H4Packet = h4.H4Packet;
pub const H4StreamParser = h4.H4StreamParser;
pub const H4Serializer = h4.H4Serializer;

pub const H5Error = h5.H5Error;
pub const H5PacketType = h5.H5PacketType;
pub const H5Header = h5.H5Header;
pub const H5Frame = h5.H5Frame;
pub const H5StreamParser = h5.H5StreamParser;
pub const H5Channel = h5.H5Channel;

pub const HciSocket = socket.HciSocket;
pub const HciError = socket.HciError;
pub const HciFilter = filter.HciFilter;
pub const HciController = controller.HciController;
pub const AclFlowController = controller.AclFlowController;
pub const HciScanConfig = controller.HciScanConfig;
pub const Commands = commands.Commands;
pub const CreateConnectionParams = commands.CreateConnectionParams;
pub const ExtCreateConnectionParams = commands.ExtCreateConnectionParams;
pub const ScanType = commands.ScanType;
pub const AddressType = commands.AddressType;
pub const ScanFilterPolicy = commands.ScanFilterPolicy;
pub const AdvType = commands.AdvType;
pub const ExtAdvProperties = commands.ExtAdvProperties;
pub const ExtAdvParams = commands.ExtAdvParams;
pub const ExtAdvDataCommand = commands.ExtAdvDataCommand;
pub const HciEvent = events.HciEvent;
pub const HciAdvertisingReport = events.HciAdvertisingReport;
pub const AdvertisingReportIterator = events.AdvertisingReportIterator;
pub const HciExtAdvertisingReport = events.HciExtAdvertisingReport;
pub const ExtAdvertisingReportIterator = events.ExtAdvertisingReportIterator;
pub const CompletedPacketEntry = events.CompletedPacketEntry;
pub const CompletedPacketsIterator = events.CompletedPacketsIterator;
pub const EventParseError = events.EventParseError;

pub const PacketType = constants.PacketType;
pub const Opcode = constants.Opcode;
pub const EventCode = constants.EventCode;
pub const LeSubevent = constants.LeSubevent;
pub const Status = constants.Status;
pub const makeOpcode = constants.makeOpcode;

pub const subrating = @import("subrating.zig");
pub const SubrateParameters = subrating.SubrateParameters;
pub const SubrateOpcode = subrating.SubrateOpcode;
pub const SubrateChangeEvent = subrating.SubrateChangeEvent;
pub const encodeSubrateRequest = subrating.encodeSubrateRequest;
pub const encodeSetDefaultSubrate = subrating.encodeSetDefaultSubrate;
pub const decodeSubrateChangeEvent = subrating.decodeSubrateChangeEvent;

test {
    std.testing.refAllDecls(@This());
    _ = constants;
    _ = filter;
    _ = commands;
    _ = events;
    _ = socket;
    _ = controller;
    _ = h4;
    _ = h5;
    _ = subrating;
}
