//! # Windows Bluetooth Radio Manager
//!
//! Enumerate and query local Bluetooth radios using native Windows Bluetooth APIs.

const std = @import("std");
const windows = std.os.windows;
const bindings = @import("bindings.zig");
const types = @import("../types.zig");
const Address = types.Address;
const BleError = types.BleError;

pub const RadioInfo = struct {
    address: Address,
    manufacturer: u16,
    name: [256]u8 = undefined,
    name_len: u8 = 0,

    pub fn getName(self: *const RadioInfo) []const u8 {
        return self.name[0..self.name_len];
    }
};

pub const WindowsRadio = struct {
    apis: bindings.WindowsBluetoothApis,
    radio_handle: ?windows.HANDLE = null,
    info: ?RadioInfo = null,

    pub fn init() ?WindowsRadio {
        const apis = bindings.WindowsBluetoothApis.load() orelse return null;
        return .{
            .apis = apis,
        };
    }

    pub fn deinit(self: *WindowsRadio) void {
        self.close();
        self.apis.unload();
    }

    pub fn openDefault(self: *WindowsRadio) !void {
        self.close();

        var radio_handle: windows.HANDLE = undefined;
        const params = bindings.BLUETOOTH_FIND_RADIO_PARAMS{};
        const find_handle = self.apis.findFirstRadio(&params, &radio_handle);

        if (find_handle) |h_find| {
            defer _ = self.apis.findRadioClose(h_find);

            var raw_info: bindings.BLUETOOTH_RADIO_INFO = std.mem.zeroes(bindings.BLUETOOTH_RADIO_INFO);
            raw_info.dwSize = @sizeOf(bindings.BLUETOOTH_RADIO_INFO);
            const res = self.apis.getRadioInfo(radio_handle, &raw_info);
            if (res != 0) {
                _ = bindings.CloseHandle(radio_handle);
                return BleError.AdapterNotFound;
            }

            var info = RadioInfo{
                .address = Address{
                    .bytes = [_]u8{
                        @intCast((raw_info.address >> 0) & 0xFF),
                        @intCast((raw_info.address >> 8) & 0xFF),
                        @intCast((raw_info.address >> 16) & 0xFF),
                        @intCast((raw_info.address >> 24) & 0xFF),
                        @intCast((raw_info.address >> 32) & 0xFF),
                        @intCast((raw_info.address >> 40) & 0xFF),
                    },
                },
                .manufacturer = raw_info.manufacturer,
            };

            var name_len: usize = 0;
            while (name_len < raw_info.szName.len and raw_info.szName[name_len] != 0) : (name_len += 1) {}
            const utf8_len = std.unicode.utf16LeToUtf8(&info.name, raw_info.szName[0..name_len]) catch 0;
            info.name_len = @intCast(utf8_len);

            self.radio_handle = radio_handle;
            self.info = info;
        } else {
            return BleError.AdapterNotFound;
        }
    }

    pub fn close(self: *WindowsRadio) void {
        if (self.radio_handle) |h| {
            _ = bindings.CloseHandle(h);
            self.radio_handle = null;
            self.info = null;
        }
    }

    pub fn isPowered(self: *const WindowsRadio) bool {
        return self.radio_handle != null;
    }

    pub fn getInfo(self: *const WindowsRadio) ?RadioInfo {
        return self.info;
    }
};

test "WindowsRadio probe test" {
    if (WindowsRadio.init()) |mut_radio| {
        var radio = mut_radio;
        defer radio.deinit();

        radio.openDefault() catch |err| {
            if (err == BleError.AdapterNotFound) return; // CI without Bluetooth hardware
            return err;
        };

        try std.testing.expect(radio.isPowered());
        const info = radio.getInfo().?;
        try std.testing.expect(info.name_len > 0);
    }
}
