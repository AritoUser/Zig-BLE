//! # Read Real Phone GATT Characteristics Over the Air with Win32 Error Reporting

const std = @import("std");
const windows = std.os.windows;
const ble = @import("Zig_BLE");
const bindings = ble.backend.windows.bindings;

pub fn main() !void {
    std.debug.print("=========================================================\n", .{});
    std.debug.print("  LIVE OVER-THE-AIR GATT READ: S25 Ultra (GAP 0x1800)    \n", .{});
    std.debug.print("=========================================================\n\n", .{});

    const bth_apis = bindings.WindowsBluetoothApis.load() orelse return;

    const dev_path = "\\\\?\\BTHLEDEVICE#{00001800-0000-1000-8000-00805F9B34FB}_78B6FE6C4EA4#B&84E7F2D&0&0014#{e0cbf06c-cd8b-4647-bb8a-263b43f0f974}";

    const kernel32 = bindings.LoadLibraryA("kernel32.dll") orelse return;
    const CreateFileAFn = *const fn (
        lpFileName: [*:0]const u8,
        dwDesiredAccess: windows.DWORD,
        dwShareMode: windows.DWORD,
        lpSecurityAttributes: ?*anyopaque,
        dwCreationDisposition: windows.DWORD,
        dwFlagsAndAttributes: windows.DWORD,
        hTemplateFile: ?windows.HANDLE,
    ) callconv(.winapi) windows.HANDLE;
    const create_file: CreateFileAFn = @ptrCast(bindings.GetProcAddress(kernel32, "CreateFileA") orelse return);
    const GetLastErrorFn = *const fn () callconv(.winapi) windows.DWORD;
    const get_last_error: GetLastErrorFn = @ptrCast(bindings.GetProcAddress(kernel32, "GetLastError") orelse return);

    const FILE_SHARE_READ: u32 = 0x00000001;
    const FILE_SHARE_WRITE: u32 = 0x00000002;
    const OPEN_EXISTING: u32 = 3;

    std.debug.print("[*] Opening Service Interface: {s}\n", .{dev_path});
    // First try with 0 access (query permissions only)
    var hDevice = create_file(dev_path, 0, FILE_SHARE_READ | FILE_SHARE_WRITE, null, OPEN_EXISTING, 0, null);
    if (hDevice == windows.INVALID_HANDLE_VALUE) {
        const err = get_last_error();
        std.debug.print("  -> Access=0 failed with GetLastError={d} (0x{X:0>4})\n", .{ err, err });
        // Try GENERIC_READ
        hDevice = create_file(dev_path, 0x80000000, FILE_SHARE_READ | FILE_SHARE_WRITE, null, OPEN_EXISTING, 0, null);
        if (hDevice == windows.INVALID_HANDLE_VALUE) {
            const err2 = get_last_error();
            std.debug.print("  -> Access=GENERIC_READ failed with GetLastError={d} (0x{X:0>4})\n", .{ err2, err2 });
            return;
        }
    }

    defer _ = bindings.CloseHandle(hDevice);
    std.debug.print("[OK] Successfully opened live service HANDLE: {*}\n", .{hDevice});

    const get_chars = bth_apis.getCharacteristics orelse return;
    const get_val = bth_apis.getCharValue orelse return;

    var chars_count: u16 = 0;
    const res = get_chars(hDevice, null, 0, null, &chars_count, 0);
    std.debug.print("[*] BluetoothGATTGetCharacteristics: status=0x{X:0>8}, count={d}\n", .{ @as(u32, @bitCast(res)), chars_count });

    if (chars_count > 0) {
        var chars: [16]bindings.BTH_LE_GATT_CHARACTERISTIC = undefined;
        const res2 = get_chars(hDevice, null, @min(16, chars_count), &chars, &chars_count, 0);
        if (res2 == 0) {
            std.debug.print("[OK] Discovered {d} live characteristics in Service 0x1800!\n", .{chars_count});
            for (chars[0..chars_count], 0..) |c, i| {
                const uuid_val = if (c.CharacteristicUuid.IsShortUuid != .FALSE)
                    c.CharacteristicUuid.Value.ShortUuid
                else
                    0;
                std.debug.print("\n  [{d}] Characteristic UUID: 0x{X:0>4} (Handle 0x{X:0>4})\n", .{ i + 1, uuid_val, c.AttributeHandle });
                std.debug.print("      Readable={}, Writable={}, Notifiable={}\n", .{
                    c.IsReadable != .FALSE, c.IsWritable != .FALSE, c.IsNotifiable != .FALSE,
                });

                if (c.IsReadable != .FALSE) {
                    var val_req_len: u16 = 0;
                    _ = get_val(hDevice, &c, 0, null, &val_req_len, 0);

                    if (val_req_len > 0) {
                        var val_buf: [256]u8 align(@alignOf(usize)) = undefined;
                        const pVal: *bindings.BTH_LE_GATT_CHARACTERISTIC_VALUE = @ptrCast(&val_buf);
                        const res_read = get_val(hDevice, &c, @intCast(val_buf.len), pVal, &val_req_len, 0);
                        if (res_read == 0) {
                            const val_slice = val_buf[@sizeOf(windows.ULONG) .. @sizeOf(windows.ULONG) + pVal.DataSize];
                            std.debug.print("      -> [LIVE READ OVER-THE-AIR]: \"{s}\" (Hex: {X})\n", .{ val_slice, val_slice });
                        } else {
                            std.debug.print("      -> Read failed with status: 0x{X:0>8}\n", .{@as(u32, @bitCast(res_read))});
                        }
                    }
                }
            }
        }
    }
}
