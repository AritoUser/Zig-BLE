//! # GATT Application Container & Dispatcher
const std = @import("std");
const builtin = @import("builtin");
const core = @import("../core/mod.zig");
const types_mod = @import("types.zig");
const windows_mod = @import("windows.zig");
const bluez_mod = @import("bluez.zig");

const Connection = types_mod.Connection;
const Message = types_mod.Message;
const ServerService = types_mod.ServerService;
const UUID = core.UUID;

pub const GattApplication = struct {
    conn: ?*Connection = null,
    app_path: [128]u8 = undefined,
    app_path_len: u8 = 0,
    adapter_path: [128]u8 = undefined,
    adapter_path_len: u8 = 0,

    services: [4]ServerService = undefined,
    service_count: usize = 0,
    is_registered: bool = false,

    pub fn init(
        conn: *Connection,
        adapter_path: [:0]const u8,
        app_path: [:0]const u8,
    ) GattApplication {
        var app = GattApplication{
            .conn = conn,
        };

        const ap_len = @min(app.app_path.len - 1, app_path.len);
        @memcpy(app.app_path[0..ap_len], app_path[0..ap_len]);
        app.app_path[ap_len] = 0;
        app.app_path_len = @intCast(ap_len);

        const ad_len = @min(app.adapter_path.len - 1, adapter_path.len);
        @memcpy(app.adapter_path[0..ad_len], adapter_path[0..ad_len]);
        app.adapter_path[ad_len] = 0;
        app.adapter_path_len = @intCast(ad_len);

        return app;
    }

    pub fn getAppPath(self: *const GattApplication) [:0]const u8 {
        return self.app_path[0..self.app_path_len :0];
    }

    pub fn getAdapterPath(self: *const GattApplication) [:0]const u8 {
        return self.adapter_path[0..self.adapter_path_len :0];
    }

    pub fn createService(self: *GattApplication, uuid: UUID, primary: bool) !*ServerService {
        if (self.service_count >= self.services.len) return error.MaxServicesReached;

        var s = &self.services[self.service_count];
        s.* = .{
            .uuid = uuid,
            .primary = primary,
            .char_count = 0,
        };

        var path_buf: [160]u8 = undefined;
        const s_path = std.fmt.bufPrintSentinel(&path_buf, "{s}/service{d}", .{ self.getAppPath(), self.service_count }, 0) catch return error.BufferTooSmall;
        const s_len = @min(s.object_path.len - 1, s_path.len);
        @memcpy(s.object_path[0..s_len], s_path[0..s_len]);
        s.object_path[s_len] = 0;
        s.object_path_len = @intCast(s_len);

        self.service_count += 1;
        return s;
    }

    pub fn addService(self: *GattApplication, service: *ServerService) !void {
        if (self.service_count >= self.services.len) return error.MaxServicesReached;
        self.services[self.service_count] = service.*;
        self.service_count += 1;
    }

    /// Registers the GATT server application with the OS Bluetooth stack:
    /// - Linux: BlueZ `org.bluez.GattManager1.RegisterApplication`
    /// - Windows: WinRT `GattServiceProvider.CreateAsync` + `IGattLocalService.CreateCharacteristicAsync`
    pub fn register(self: *GattApplication) !void {
        if (builtin.os.tag == .linux) {
            return bluez_mod.registerLinux(self);
        } else if (builtin.os.tag == .windows) {
            return windows_mod.registerWindows(self);
        } else {
            return error.NotSupported;
        }
    }

    /// Unregisters the GATT application from the OS Bluetooth stack.
    pub fn unregister(self: *GattApplication) !void {
        if (builtin.os.tag == .linux) {
            return bluez_mod.unregisterLinux(self);
        } else if (builtin.os.tag == .windows) {
            for (self.services[0..self.service_count]) |*s| {
                s.releaseWindows();
            }
            self.is_registered = false;
        } else {
            return error.NotSupported;
        }
    }

    /// Handles incoming D-Bus method calls (GetManagedObjects, ReadValue, WriteValue, StartNotify, StopNotify).
    pub fn processMessage(self: *GattApplication, msg: *const Message) !bool {
        return bluez_mod.processMessage(self, msg);
    }
};

