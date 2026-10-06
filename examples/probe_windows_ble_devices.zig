//! # Probe Real Windows BLE Device Interfaces
//!
//! Enumerates GUID_BLUETOOTHLE_DEVICE_INTERFACE using SetupAPI
//! and queries GATT services using BluetoothApis.dll.

const std = @import("std");
const windows = std.os.windows;
const ble = @import("Zig_BLE");
const bindings = ble.backend.windows.bindings;

const GUID = bindings.GUID;

// {781aee18-7733-4864-aa85-ddcd1fde77db}
const GUID_BLUETOOTHLE_DEVICE_INTERFACE = GUID{
    .Data1 = 0x781aee18,
    .Data2 = 0x7733,
    .Data3 = 0x4864,
    .Data4 = [_]u8{ 0xaa, 0x85, 0xdd, 0xcd, 0x1f, 0xde, 0x77, 0xdb },
};

const DIGCF_PRESENT: u32 = 0x00000002;
const DIGCF_DEVICEINTERFACE: u32 = 0x00000010;

const SP_DEVICE_INTERFACE_DATA = extern struct {
    cbSize: windows.DWORD = @sizeOf(SP_DEVICE_INTERFACE_DATA),
    InterfaceClassGuid: GUID,
    Flags: windows.DWORD = 0,
    Reserved: windows.ULONG_PTR = 0,
};

const SetupDiGetClassDevsAFn = *const fn (
    ClassGuid: ?*const GUID,
    Enumerator: ?[*:0]const u8,
    hwndParent: ?windows.HWND,
    Flags: windows.DWORD,
) callconv(.winapi) windows.HANDLE;

const SetupDiEnumDeviceInterfacesFn = *const fn (
    DeviceInfoSet: windows.HANDLE,
    DeviceInfoData: ?*anyopaque,
    InterfaceClassGuid: *const GUID,
    MemberIndex: windows.DWORD,
    DeviceInterfaceData: *SP_DEVICE_INTERFACE_DATA,
) callconv(.winapi) windows.BOOL;

const SetupDiGetDeviceInterfaceDetailAFn = *const fn (
    DeviceInfoSet: windows.HANDLE,
    DeviceInterfaceData: *SP_DEVICE_INTERFACE_DATA,
    DeviceInterfaceDetailData: ?[*]u8,
    DeviceInterfaceDetailDataSize: windows.DWORD,
    RequiredSize: ?*windows.DWORD,
    DeviceInfoData: ?*anyopaque,
) callconv(.winapi) windows.BOOL;

const SetupDiDestroyDeviceInfoListFn = *const fn (
    DeviceInfoSet: windows.HANDLE,
) callconv(.winapi) windows.BOOL;

pub fn main() !void {
    std.debug.print("=========================================================\n", .{});
    std.debug.print("   Probing Native Windows BLE Device Interfaces & GATT   \n", .{});
    std.debug.print("=========================================================\n", .{});

    const bth_apis = bindings.WindowsBluetoothApis.load() orelse {
        std.debug.print("[!] Could not load BluetoothApis.dll / bthprops.cpl\n", .{});
        return;
    };
    std.debug.print("[OK] BluetoothApis loaded.\n", .{});

    const setupapi = bindings.LoadLibraryA("setupapi.dll") orelse {
        std.debug.print("[!] Could not load setupapi.dll\n", .{});
        return;
    };
    defer _ = bindings.FreeLibrary(setupapi);

    const get_class_devs: SetupDiGetClassDevsAFn = @ptrCast(bindings.GetProcAddress(setupapi, "SetupDiGetClassDevsA") orelse return);
    const enum_interfaces: SetupDiEnumDeviceInterfacesFn = @ptrCast(bindings.GetProcAddress(setupapi, "SetupDiEnumDeviceInterfaces") orelse return);
    const get_detail: SetupDiGetDeviceInterfaceDetailAFn = @ptrCast(bindings.GetProcAddress(setupapi, "SetupDiGetDeviceInterfaceDetailA") orelse return);
    const destroy_list: SetupDiDestroyDeviceInfoListFn = @ptrCast(bindings.GetProcAddress(setupapi, "SetupDiDestroyDeviceInfoList") orelse return);

    const hDevInfo = get_class_devs(
        &GUID_BLUETOOTHLE_DEVICE_INTERFACE,
        null,
        null,
        DIGCF_DEVICEINTERFACE | DIGCF_PRESENT,
    );

    if (hDevInfo == windows.INVALID_HANDLE_VALUE) {
        std.debug.print("[!] SetupDiGetClassDevs returned INVALID_HANDLE_VALUE\n", .{});
        return;
    }
    defer _ = destroy_list(hDevInfo);

    std.debug.print("[*] Enumerating active Bluetooth LE Device Interfaces in Windows...\n", .{});

    var index: u32 = 0;
    var found_count: usize = 0;

    while (true) : (index += 1) {
        var if_data = SP_DEVICE_INTERFACE_DATA{
            .InterfaceClassGuid = GUID_BLUETOOTHLE_DEVICE_INTERFACE,
        };

        if (enum_interfaces(hDevInfo, null, &GUID_BLUETOOTHLE_DEVICE_INTERFACE, index, &if_data) == .FALSE) {
            break;
        }

        found_count += 1;
        var required_size: windows.DWORD = 0;
        _ = get_detail(hDevInfo, &if_data, null, 0, &required_size, null);

        var detail_buf: [1024]u8 align(@alignOf(usize)) = undefined;
        // First DWORD of SP_DEVICE_INTERFACE_DETAIL_DATA is cbSize (which is 8 on 64-bit Windows A)
        const cbSize: u32 = if (@sizeOf(usize) == 8) 8 else 5;
        std.mem.writeInt(u32, @ptrCast(detail_buf[0..4]), cbSize, .little);

        if (get_detail(hDevInfo, &if_data, &detail_buf, @intCast(detail_buf.len), null, null) != .FALSE) {
            const path_slice = std.mem.sliceTo(detail_buf[4..], 0);
            std.debug.print("  [{d}] Found BLE Device Interface Path:\n      {s}\n", .{ found_count, path_slice });

            // Try opening handle to device
            const kernel32 = bindings.LoadLibraryA("kernel32.dll") orelse continue;
            const CreateFileAFn = *const fn (
                lpFileName: [*:0]const u8,
                dwDesiredAccess: windows.DWORD,
                dwShareMode: windows.DWORD,
                lpSecurityAttributes: ?*anyopaque,
                dwCreationDisposition: windows.DWORD,
                dwFlagsAndAttributes: windows.DWORD,
                hTemplateFile: ?windows.HANDLE,
            ) callconv(.winapi) windows.HANDLE;
            const create_file: CreateFileAFn = @ptrCast(bindings.GetProcAddress(kernel32, "CreateFileA") orelse continue);

            var path_z: [1024:0]u8 = undefined;
            @memcpy(path_z[0..path_slice.len], path_slice);
            path_z[path_slice.len] = 0;

            const GENERIC_READ: u32 = 0x80000000;
            const GENERIC_WRITE: u32 = 0x40000000;
            const FILE_SHARE_READ: u32 = 0x00000001;
            const FILE_SHARE_WRITE: u32 = 0x00000002;
            const OPEN_EXISTING: u32 = 3;

            const hDevice = create_file(&path_z, GENERIC_READ | GENERIC_WRITE, FILE_SHARE_READ | FILE_SHARE_WRITE, null, OPEN_EXISTING, 0, null);
            if (hDevice != windows.INVALID_HANDLE_VALUE) {
                defer _ = bindings.CloseHandle(hDevice);
                std.debug.print("      -> Successfully opened device HANDLE: {*}\n", .{hDevice});

                if (bth_apis.getServices) |get_services| {
                    var services_actual: u16 = 0;
                    const res = get_services(hDevice, 0, null, &services_actual, 0);
                    std.debug.print("      -> BluetoothGATTGetServices returned: 0x{X:0>8}, Service count: {d}\n", .{ @as(u32, @bitCast(res)), services_actual });

                    if (services_actual > 0) {
                        var services: [16]bindings.BTH_LE_GATT_SERVICE = undefined;
                        const res2 = get_services(hDevice, @min(16, services_actual), &services, &services_actual, 0);
                        if (res2 == 0) {
                            for (services[0..services_actual]) |srv| {
                                std.debug.print("         - Service Handle: 0x{X:0>4}, UUID IsShort={}\n", .{ srv.AttributeHandle, srv.ServiceUuid.IsShortUuid != .FALSE });
                            }
                        }
                    }
                }
            } else {
                std.debug.print("      -> CreateFile failed (Device might be disconnected or require admin rights)\n", .{});
            }
        }
    }

    if (found_count == 0) {
        std.debug.print("\n[*] Keine registrierten BLE-GATT Geräte-Interfaces in Windows gefunden.\n", .{});
        std.debug.print("    (Hinweis: Windows erstellt erst dann ein GUID_BLUETOOTHLE_DEVICE_INTERFACE,\n", .{});
        std.debug.print("    wenn ein BLE-Gerät mindestens einmal gekoppelt oder verbunden wurde.)\n", .{});
    }
}
