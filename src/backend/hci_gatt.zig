//! # HciBackend: ATT responses and GATT discovery

const std = @import("std");
const types = @import("types.zig");
const core = @import("../core/mod.zig");
const att = core.att;
const backend_mod = @import("hci.zig");

const HciBackend = backend_mod.HciBackend;
const HciDeviceContext = backend_mod.HciDeviceContext;
const DiscoveredCharacteristic = backend_mod.DiscoveredCharacteristic;
const cccd_uuid = backend_mod.cccd_uuid;
const UUID = types.UUID;
const BleError = types.BleError;

pub fn onAttError(self: *HciBackend, dev: *HciDeviceContext, code: att.AttErrorCode) BleError!void {
    if (!dev.pending_disc) {
        dev.last_att_error = code;
        dev.op_done = true;
        return;
    }
    // Attribute Not Found is how a peer says the current phase is finished.
    if (code != .attribute_not_found) {
        dev.last_att_error = code;
        dev.pending_disc = false;
        return;
    }
    dev.disc.advancePhase();
    try discoveryStep(self, dev);
}

pub fn onAttResponse(self: *HciBackend, dev: *HciDeviceContext, rsp: att.AttPdu) BleError!void {
    switch (rsp) {
        .read_rsp => |r| {
            const copy_len = @min(r.value.len, dev.last_read_buf.len);
            @memcpy(dev.last_read_buf[0..copy_len], r.value[0..copy_len]);
            dev.last_read_len = copy_len;
            dev.op_done = true;
        },
        .write_rsp => dev.op_done = true,
        .exchange_mtu_rsp => |r| {
            dev.att_bearer.mtu = @max(23, @min(dev.att_bearer.local_max_mtu, r.server_rx_mtu));
            dev.op_done = true;
        },
        .read_by_group_type_rsp => |r| {
            var last_handle: u16 = 0xFFFF;
            var it = r.iterator();
            while (it.next()) |elem| {
                last_handle = elem.end_handle;
                if (dev.services_len == dev.services.len) {
                    dev.discovery_overflow = true;
                    continue;
                }
                dev.services[dev.services_len] = .{ .start_handle = elem.start_handle, .end_handle = elem.end_handle, .uuid = elem.uuid };
                dev.services_len += 1;
            }
            dev.disc.advanceOnEndHandle(last_handle);
            try discoveryStep(self, dev);
        },
        .read_by_type_rsp => |r| {
            var last_handle: u16 = 0xFFFF;
            var it = r.iterator();
            while (it.next()) |elem| {
                last_handle = elem.handle;
                // Characteristic declaration: properties, value handle, 16- or 128-bit UUID
                if (elem.value.len != 5 and elem.value.len != 19) continue;
                if (dev.characteristics_len == dev.characteristics.len) {
                    dev.discovery_overflow = true;
                    continue;
                }
                const uuid = if (elem.value.len == 5)
                    UUID.from16(std.mem.readInt(u16, elem.value[3..5], .little))
                else
                    UUID.fromLittleEndian(elem.value[3..19].*);
                dev.characteristics[dev.characteristics_len] = .{
                    .uuid = uuid,
                    .decl_handle = elem.handle,
                    .value_handle = std.mem.readInt(u16, elem.value[1..3], .little),
                    .properties = core.CharacteristicProperties.fromByte(elem.value[0]),
                    .active = true,
                };
                dev.characteristics_len += 1;
            }
            dev.disc.advanceOnEndHandle(last_handle);
            try discoveryStep(self, dev);
        },
        .find_info_rsp => |r| {
            var last_handle: u16 = 0xFFFF;
            var it = r.iterator();
            while (it.next()) |item| {
                last_handle = item.handle;
                recordDescriptor(dev, item.handle, item.uuid);
            }
            dev.disc.advanceOnEndHandle(last_handle);
            try discoveryStep(self, dev);
        },
        else => {},
    }
}

/// Finds the characteristic a descriptor belongs to: the last one declared before it.
fn recordDescriptor(dev: *HciDeviceContext, handle: u16, uuid: UUID) void {
    var is_descriptor = false;
    for (0x2900..0x2920) |short| {
        if (uuid.eql(UUID.from16(@intCast(short)))) is_descriptor = true;
    }
    if (!is_descriptor) return;

    var owner: ?*DiscoveredCharacteristic = null;
    for (dev.characteristics[0..dev.characteristics_len]) |*ch| {
        if (ch.value_handle < handle) owner = ch;
    }
    const ch = owner orelse return;
    if (uuid.eql(cccd_uuid)) {
        ch.cccd_handle = handle;
    } else if (dev.descriptors_len < dev.descriptors.len) {
        dev.descriptors[dev.descriptors_len] = .{ .handle = handle, .uuid = uuid, .owner_value_handle = ch.value_handle };
        dev.descriptors_len += 1;
    }
}

/// Sends the next discovery request, or finishes discovery if none is left.
pub fn discoveryStep(self: *HciBackend, dev: *HciDeviceContext) BleError!void {
    if (!dev.pending_disc) return;
    if (dev.disc.nextRequest()) |req| {
        var pdu_buf: [32]u8 = undefined;
        const len = dev.att_bearer.beginRequest(req, 0, &pdu_buf) catch return BleError.GattError;
        return self.sendL2capOverAcl(dev.conn_handle, att.ATT_CID, pdu_buf[0..len]);
    }
    for (dev.characteristics[0..dev.characteristics_len]) |*ch| {
        for (dev.services[0..dev.services_len]) |svc| {
            if (ch.decl_handle >= svc.start_handle and ch.decl_handle <= svc.end_handle) {
                ch.service_uuid = svc.uuid;
                break;
            }
        }
    }
    dev.pending_disc = false;
}
