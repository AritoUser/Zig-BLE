//! # GATT Server Unit Tests
const std = @import("std");
const core = @import("../core/mod.zig");
const types_mod = @import("types.zig");

const UUID = core.UUID;
const ServerService = types_mod.ServerService;
const ServerCharacteristic = types_mod.ServerCharacteristic;
const ServerCharacteristicFlags = types_mod.ServerCharacteristicFlags;
const ServerDescriptorFlags = types_mod.ServerDescriptorFlags;

test "ServerCharacteristic: initialization and value update" {
    var char = ServerCharacteristic{
        .uuid = UUID.from16(0x2A37),
        .flags = .{ .read = true, .notify = true },
    };
    try std.testing.expectEqual(@as(u8, 0), char.value_len);

    char.setValue(&[_]u8{ 0x00, 0x48 }); // 72 bpm
    try std.testing.expectEqual(@as(u8, 2), char.value_len);
    try std.testing.expectEqualSlices(u8, &[_]u8{ 0x00, 0x48 }, char.getValue());
}

test "ServerService: add characteristics within limit" {
    var s = ServerService{
        .uuid = UUID.from16(0x180D),
        .primary = true,
    };
    const c1 = try s.addCharacteristic(UUID.from16(0x2A37), .{ .notify = true });
    try std.testing.expect(c1.flags.notify);
    try std.testing.expectEqual(@as(usize, 1), s.char_count);

    const c2 = try s.addCharacteristic(UUID.from16(0x2A38), .{ .read = true });
    try std.testing.expect(c2.flags.read);
    try std.testing.expectEqual(@as(usize, 2), s.char_count);
}

test "ServerCharacteristic: add descriptor and set user description" {
    var s = ServerService{
        .uuid = UUID.from16(0x180D),
        .primary = true,
    };
    const s_path = "/org/zig_ble/app0/service0";
    @memcpy(s.object_path[0..s_path.len], s_path);
    s.object_path[s_path.len] = 0;
    s.object_path_len = s_path.len;

    const c = try s.addCharacteristic(UUID.from16(0x2A37), .{ .notify = true });

    const desc = try c.setUserDescription("Heart Rate Monitor");
    try std.testing.expectEqual(@as(usize, 1), c.desc_count);
    try std.testing.expectEqualStrings("Heart Rate Monitor", desc.getValue());
    try std.testing.expect(desc.flags.read);
    try std.testing.expect(desc.uuid.eql(UUID.from16(0x2901)));
    try std.testing.expectEqualStrings("/org/zig_ble/app0/service0/char0/desc0", desc.getObjectPath());
}

test "ServerCharacteristic: setTyped and getTyped with Sfloat" {
    var char = ServerCharacteristic{
        .uuid = UUID.from16(0x2A1C), // Temperature Measurement
        .flags = .{ .read = true },
    };
    const s = core.Sfloat.fromF32(36.8);
    try char.setTyped(s);

    const retrieved = try char.getTyped(core.Sfloat);
    try std.testing.expectEqual(s.raw, retrieved.raw);
    try std.testing.expectApproxEqAbs(@as(f32, 36.8), try retrieved.toF32(), 0.01);
}

test "ServerCharacteristic: setPresentationFormat" {
    var s = ServerService{
        .uuid = UUID.from16(0x1809), // Health Thermometer
        .primary = true,
    };
    const s_path = "/org/zig_ble/app0/service0";
    @memcpy(s.object_path[0..s_path.len], s_path);
    s.object_path[s_path.len] = 0;
    s.object_path_len = s_path.len;

    const c = try s.addCharacteristic(UUID.from16(0x2A1C), .{ .read = true });
    const cpf_desc = try c.setPresentationFormat(.{
        .format = .sfloat,
        .exponent = 0,
        .unit = core.Units.celsius,
    });

    try std.testing.expectEqual(@as(usize, 1), c.desc_count);
    try std.testing.expect(cpf_desc.uuid.eql(UUID.from16(0x2904)));
    const decoded_cpf = try cpf_desc.getTyped(core.CharacteristicPresentationFormat);
    try std.testing.expectEqual(core.FormatType.sfloat, decoded_cpf.format);
    try std.testing.expectEqual(core.Units.celsius, decoded_cpf.unit);
}

test "ServerCharacteristicFlags & ServerDescriptorFlags: security and permission flags" {
    const flags = ServerCharacteristicFlags{
        .read = true,
        .write = true,
        .encrypt_read = true,
        .encrypt_authenticated_write = true,
        .secure_read = true,
        .authorize = true,
    };
    var out_buf: [12][:0]const u8 = undefined;
    const slice = flags.toBluezFlags(&out_buf);
    try std.testing.expectEqual(@as(usize, 6), slice.len);
    try std.testing.expectEqualStrings("read", slice[0]);
    try std.testing.expectEqualStrings("write", slice[1]);
    try std.testing.expectEqualStrings("encrypt-read", slice[2]);
    try std.testing.expectEqualStrings("encrypt-authenticated-write", slice[3]);
    try std.testing.expectEqualStrings("secure-read", slice[4]);
    try std.testing.expectEqualStrings("authorize", slice[5]);

    try std.testing.expectEqual(@as(i32, 3), flags.toWinRtReadProtection());
    try std.testing.expectEqual(@as(i32, 3), flags.toWinRtWriteProtection());
    try std.testing.expectEqual(@as(u32, 0x2 | 0x8), flags.toWinRtProperties());

    const dflags = ServerDescriptorFlags{
        .read = true,
        .encrypt_read = true,
        .secure_write = true,
        .authorize = true,
    };
    var dout_buf: [9][:0]const u8 = undefined;
    const dslice = dflags.toBluezFlags(&dout_buf);
    try std.testing.expectEqual(@as(usize, 4), dslice.len);
    try std.testing.expectEqualStrings("read", dslice[0]);
    try std.testing.expectEqualStrings("encrypt-read", dslice[1]);
    try std.testing.expectEqualStrings("secure-write", dslice[2]);
    try std.testing.expectEqualStrings("authorize", dslice[3]);
}

