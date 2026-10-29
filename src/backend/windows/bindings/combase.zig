//! # Dynamic WinRT combase.dll Loader
const std = @import("std");
const builtin = @import("builtin");
const types = @import("types.zig");
const bthprops = @import("bthprops.zig");
const interfaces = @import("interfaces.zig");

const WINAPI = types.WINAPI;
const HRESULT = types.HRESULT;
const HSTRING = types.HSTRING;
const GUID = types.GUID;
const E_FAIL = types.E_FAIL;
const LoadLibraryA = bthprops.LoadLibraryA;
const GetProcAddress = bthprops.GetProcAddress;

const IInspectable = interfaces.IInspectable;

pub const Combase = if (builtin.os.tag == .windows) struct {
    const HMODULE = std.os.windows.HMODULE;
    const FARPROC = std.os.windows.FARPROC;

    const RoInitializeFn = *const fn (initType: u32) callconv(WINAPI) HRESULT;
    const RoUninitializeFn = *const fn () callconv(WINAPI) void;
    const RoGetActivationFactoryFn = *const fn (activatableClassId: HSTRING, iid: *const GUID, factory: *?*anyopaque) callconv(WINAPI) HRESULT;
    const RoActivateInstanceFn = *const fn (activatableClassId: HSTRING, instance: *?*IInspectable) callconv(WINAPI) HRESULT;
    const WindowsCreateStringFn = *const fn (sourceString: ?[*]const u16, length: u32, string: *HSTRING) callconv(WINAPI) HRESULT;
    const WindowsDeleteStringFn = *const fn (string: HSTRING) callconv(WINAPI) HRESULT;
    const WindowsGetStringRawBufferFn = *const fn (string: HSTRING, length: ?*u32) callconv(WINAPI) ?[*]const u16;

    var module_handle: ?HMODULE = null;

    fn getModule() ?HMODULE {
        if (module_handle) |h| return h;
        const h = LoadLibraryA("combase.dll") orelse return null;
        module_handle = h;
        return h;
    }

    pub fn RoInitialize(initType: u32) HRESULT {
        const m = getModule() orelse return E_FAIL;
        const f: RoInitializeFn = @ptrCast(GetProcAddress(m, "RoInitialize") orelse return E_FAIL);
        return f(initType);
    }

    pub fn RoUninitialize() void {
        const m = getModule() orelse return;
        const f: RoUninitializeFn = @ptrCast(GetProcAddress(m, "RoUninitialize") orelse return);
        f();
    }

    pub fn RoGetActivationFactory(activatableClassId: HSTRING, iid: *const GUID, factory: *?*anyopaque) HRESULT {
        const m = getModule() orelse return E_FAIL;
        const f: RoGetActivationFactoryFn = @ptrCast(GetProcAddress(m, "RoGetActivationFactory") orelse return E_FAIL);
        return f(activatableClassId, iid, factory);
    }

    pub fn RoActivateInstance(activatableClassId: HSTRING, instance: *?*IInspectable) HRESULT {
        const m = getModule() orelse return E_FAIL;
        const f: RoActivateInstanceFn = @ptrCast(GetProcAddress(m, "RoActivateInstance") orelse return E_FAIL);
        return f(activatableClassId, instance);
    }

    pub fn WindowsCreateString(sourceString: ?[*]const u16, length: u32, string: *HSTRING) HRESULT {
        const m = getModule() orelse return E_FAIL;
        const f: WindowsCreateStringFn = @ptrCast(GetProcAddress(m, "WindowsCreateString") orelse return E_FAIL);
        return f(sourceString, length, string);
    }

    pub fn WindowsDeleteString(string: HSTRING) HRESULT {
        const m = getModule() orelse return E_FAIL;
        const f: WindowsDeleteStringFn = @ptrCast(GetProcAddress(m, "WindowsDeleteString") orelse return E_FAIL);
        return f(string);
    }

    pub fn WindowsGetStringRawBuffer(string: HSTRING, length: ?*u32) ?[*]const u16 {
        const m = getModule() orelse return null;
        const f: WindowsGetStringRawBufferFn = @ptrCast(GetProcAddress(m, "WindowsGetStringRawBuffer") orelse return null);
        return f(string, length);
    }
} else struct {};
