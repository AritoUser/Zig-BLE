//! # WinRT COM Event Handler Delegates (Zero-Allocation, MTA-Safe)
const std = @import("std");
const types = @import("types.zig");
const iids = @import("iids.zig");
const interfaces = @import("interfaces.zig");

const WINAPI = types.WINAPI;
const HRESULT = types.HRESULT;
const ULONG = types.ULONG;
const GUID = types.GUID;
const S_OK = types.S_OK;
const E_NOINTERFACE = types.E_NOINTERFACE;

const IID_IUnknown = iids.IID_IUnknown;
const IID_IAgileObject = iids.IID_IAgileObject;

fn makeVtbl(comptime T: type, comptime SenderType: type, comptime ArgsType: type, comptime iid: GUID) T.Vtbl {
    const Impl = struct {
        fn queryInterface(self: *T, riid: *const GUID, ppvObject: *?*anyopaque) callconv(WINAPI) HRESULT {
            if (riid.eql(IID_IUnknown) or riid.eql(IID_IAgileObject) or riid.eql(iid)) {
                ppvObject.* = @ptrCast(self);
                _ = self.ref_count.fetchAdd(1, .monotonic);
                return S_OK;
            }
            ppvObject.* = null;
            return E_NOINTERFACE;
        }

        fn addRef(self: *T) callconv(WINAPI) ULONG {
            return self.ref_count.fetchAdd(1, .monotonic) + 1;
        }

        fn release(self: *T) callconv(WINAPI) ULONG {
            const prev = self.ref_count.fetchSub(1, .monotonic);
            return if (prev > 0) prev - 1 else 0;
        }

        fn invoke(self: *T, sender: ?*SenderType, args: ?*ArgsType) callconv(WINAPI) HRESULT {
            if (!self.active.load(.acquire)) return S_OK;
            if (@hasField(T, "on_received")) {
                if (args) |a| self.on_received(self.backend_ctx, a);
            } else if (@hasField(T, "on_changed")) {
                if (args) |a| self.on_changed(self.char_ctx, a);
            } else if (@hasField(T, "on_status_changed")) {
                self.on_status_changed(self.dev_ctx, sender);
            } else if (@hasField(T, "on_pairing_requested")) {
                if (args) |a| self.on_pairing_requested(self.pair_ctx, a);
            } else if (@hasField(T, "on_read_requested")) {
                if (args) |a| self.on_read_requested(self.char_ctx, a);
            } else if (@hasField(T, "on_write_requested")) {
                if (args) |a| self.on_write_requested(self.char_ctx, a);
            }
            return S_OK;
        }
    };

    return .{
        .QueryInterface = Impl.queryInterface,
        .AddRef = Impl.addRef,
        .Release = Impl.release,
        .Invoke = Impl.invoke,
    };
}

pub const AdvertisementReceivedHandler = extern struct {
    lpVtbl: *const Vtbl = &vtbl_instance,
    ref_count: std.atomic.Value(u32) = std.atomic.Value(u32).init(1),
    active: std.atomic.Value(bool) = std.atomic.Value(bool).init(true),
    backend_ctx: *anyopaque,
    on_received: *const fn (ctx: *anyopaque, args: *interfaces.IBluetoothLEAdvertisementReceivedEventArgs) callconv(.c) void,

    pub const Vtbl = extern struct {
        QueryInterface: *const fn (self: *AdvertisementReceivedHandler, riid: *const GUID, ppvObject: *?*anyopaque) callconv(WINAPI) HRESULT,
        AddRef: *const fn (self: *AdvertisementReceivedHandler) callconv(WINAPI) ULONG,
        Release: *const fn (self: *AdvertisementReceivedHandler) callconv(WINAPI) ULONG,
        Invoke: *const fn (self: *AdvertisementReceivedHandler, sender: ?*anyopaque, args: ?*interfaces.IBluetoothLEAdvertisementReceivedEventArgs) callconv(WINAPI) HRESULT,
    };

    const vtbl_instance = makeVtbl(AdvertisementReceivedHandler, anyopaque, interfaces.IBluetoothLEAdvertisementReceivedEventArgs, iids.IID_ITypedEventHandler_Watcher_Received);

    pub fn deactivate(self: *AdvertisementReceivedHandler) void {
        self.active.store(false, .release);
    }
};

pub const GattValueChangedHandler = extern struct {
    lpVtbl: *const Vtbl = &vtbl_instance,
    ref_count: std.atomic.Value(u32) = std.atomic.Value(u32).init(1),
    active: std.atomic.Value(bool) = std.atomic.Value(bool).init(true),
    char_ctx: *anyopaque,
    on_changed: *const fn (ctx: *anyopaque, args: *interfaces.IGattValueChangedEventArgs) callconv(.c) void,

    pub const Vtbl = extern struct {
        QueryInterface: *const fn (self: *GattValueChangedHandler, riid: *const GUID, ppvObject: *?*anyopaque) callconv(WINAPI) HRESULT,
        AddRef: *const fn (self: *GattValueChangedHandler) callconv(WINAPI) ULONG,
        Release: *const fn (self: *GattValueChangedHandler) callconv(WINAPI) ULONG,
        Invoke: *const fn (self: *GattValueChangedHandler, sender: ?*anyopaque, args: ?*interfaces.IGattValueChangedEventArgs) callconv(WINAPI) HRESULT,
    };

    const vtbl_instance = makeVtbl(GattValueChangedHandler, anyopaque, interfaces.IGattValueChangedEventArgs, iids.IID_ITypedEventHandler_Characteristic_ValueChanged);

    pub fn deactivate(self: *GattValueChangedHandler) void {
        self.active.store(false, .release);
    }
};

pub const ConnectionStatusChangedHandler = extern struct {
    lpVtbl: *const Vtbl = &vtbl_instance,
    ref_count: std.atomic.Value(u32) = std.atomic.Value(u32).init(1),
    active: std.atomic.Value(bool) = std.atomic.Value(bool).init(true),
    dev_ctx: *anyopaque,
    on_status_changed: *const fn (ctx: *anyopaque, sender: ?*interfaces.IBluetoothLEDevice) callconv(.c) void,

    pub const Vtbl = extern struct {
        QueryInterface: *const fn (self: *ConnectionStatusChangedHandler, riid: *const GUID, ppvObject: *?*anyopaque) callconv(WINAPI) HRESULT,
        AddRef: *const fn (self: *ConnectionStatusChangedHandler) callconv(WINAPI) ULONG,
        Release: *const fn (self: *ConnectionStatusChangedHandler) callconv(WINAPI) ULONG,
        Invoke: *const fn (self: *ConnectionStatusChangedHandler, sender: ?*interfaces.IBluetoothLEDevice, args: ?*anyopaque) callconv(WINAPI) HRESULT,
    };

    const vtbl_instance = makeVtbl(ConnectionStatusChangedHandler, interfaces.IBluetoothLEDevice, anyopaque, iids.IID_ITypedEventHandler_BluetoothLEDevice_IInspectable);

    pub fn deactivate(self: *ConnectionStatusChangedHandler) void {
        self.active.store(false, .release);
    }
};

pub const PairingRequestedHandler = extern struct {
    lpVtbl: *const Vtbl = &vtbl_instance,
    ref_count: std.atomic.Value(u32) = std.atomic.Value(u32).init(1),
    active: std.atomic.Value(bool) = std.atomic.Value(bool).init(true),
    pair_ctx: *anyopaque,
    on_pairing_requested: *const fn (ctx: *anyopaque, args: *interfaces.IDevicePairingRequestedEventArgs) callconv(.c) void,

    pub const Vtbl = extern struct {
        QueryInterface: *const fn (self: *PairingRequestedHandler, riid: *const GUID, ppvObject: *?*anyopaque) callconv(WINAPI) HRESULT,
        AddRef: *const fn (self: *PairingRequestedHandler) callconv(WINAPI) ULONG,
        Release: *const fn (self: *PairingRequestedHandler) callconv(WINAPI) ULONG,
        Invoke: *const fn (self: *PairingRequestedHandler, sender: ?*anyopaque, args: ?*interfaces.IDevicePairingRequestedEventArgs) callconv(WINAPI) HRESULT,
    };

    const vtbl_instance = makeVtbl(PairingRequestedHandler, anyopaque, interfaces.IDevicePairingRequestedEventArgs, iids.IID_ITypedEventHandler_CustomPairing_PairingRequested);

    pub fn deactivate(self: *PairingRequestedHandler) void {
        self.active.store(false, .release);
    }
};

pub const GattReadRequestedHandler = extern struct {
    lpVtbl: *const Vtbl = &vtbl_instance,
    ref_count: std.atomic.Value(u32) = std.atomic.Value(u32).init(1),
    active: std.atomic.Value(bool) = std.atomic.Value(bool).init(true),
    char_ctx: *anyopaque,
    on_read_requested: *const fn (ctx: *anyopaque, args: *interfaces.IGattReadRequestedEventArgs) callconv(.c) void,

    pub const Vtbl = extern struct {
        QueryInterface: *const fn (self: *GattReadRequestedHandler, riid: *const GUID, ppvObject: *?*anyopaque) callconv(WINAPI) HRESULT,
        AddRef: *const fn (self: *GattReadRequestedHandler) callconv(WINAPI) ULONG,
        Release: *const fn (self: *GattReadRequestedHandler) callconv(WINAPI) ULONG,
        Invoke: *const fn (self: *GattReadRequestedHandler, sender: ?*anyopaque, args: ?*interfaces.IGattReadRequestedEventArgs) callconv(WINAPI) HRESULT,
    };

    const vtbl_instance = makeVtbl(GattReadRequestedHandler, anyopaque, interfaces.IGattReadRequestedEventArgs, iids.IID_ITypedEventHandler_GattLocalCharacteristic_ReadRequested);

    pub fn deactivate(self: *GattReadRequestedHandler) void {
        self.active.store(false, .release);
    }
};

pub const GattWriteRequestedHandler = extern struct {
    lpVtbl: *const Vtbl = &vtbl_instance,
    ref_count: std.atomic.Value(u32) = std.atomic.Value(u32).init(1),
    active: std.atomic.Value(bool) = std.atomic.Value(bool).init(true),
    char_ctx: *anyopaque,
    on_write_requested: *const fn (ctx: *anyopaque, args: *interfaces.IGattWriteRequestedEventArgs) callconv(.c) void,

    pub const Vtbl = extern struct {
        QueryInterface: *const fn (self: *GattWriteRequestedHandler, riid: *const GUID, ppvObject: *?*anyopaque) callconv(WINAPI) HRESULT,
        AddRef: *const fn (self: *GattWriteRequestedHandler) callconv(WINAPI) ULONG,
        Release: *const fn (self: *GattWriteRequestedHandler) callconv(WINAPI) ULONG,
        Invoke: *const fn (self: *GattWriteRequestedHandler, sender: ?*anyopaque, args: ?*interfaces.IGattWriteRequestedEventArgs) callconv(WINAPI) HRESULT,
    };

    const vtbl_instance = makeVtbl(GattWriteRequestedHandler, anyopaque, interfaces.IGattWriteRequestedEventArgs, iids.IID_ITypedEventHandler_GattLocalCharacteristic_WriteRequested);

    pub fn deactivate(self: *GattWriteRequestedHandler) void {
        self.active.store(false, .release);
    }
};
