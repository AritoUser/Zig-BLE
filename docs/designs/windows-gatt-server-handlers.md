# Windows GATT server: request handlers that outlive `unregister`

Status: draft, 2026-11-16. Reviewed once (codebase details, design, zoom-out); findings
resolved in this version. Awaiting maintainer approval.

## Problem

The GATT server on Windows registers `ReadRequested` and `WriteRequested` handlers on each
local characteristic (`src/gatt_server/windows.zig`, `registerWindows`) and on each local
descriptor (`registerDescriptor`). The handler objects are fields of `ServerCharacteristic`
and `ServerDescriptor` (`src/gatt_server/types.zig`), so they live in the caller's
`GattApplication`.

WinRT holds references to these handlers. `remove_ReadRequested` and `remove_WriteRequested`
do not wait for a call that is already running, and WinRT may call `Release` (or `Invoke`, for
a call already dispatched) after them. Three things can go wrong:

1. **Use after free after `unregister`.** `unregister` (`src/gatt_server/app.zig`) deactivates
   and removes the handlers, releases the local characteristics, stops advertising and
   releases the providers, then returns. If the caller then frees or reuses the
   `GattApplication`, a late `Release` writes the reference count into freed memory and a
   late `Invoke` reads `active` from it.
2. **A request in flight keeps using the characteristic.** `onRead` and `onWrite` wait up to
   5 s for `GetRequestAsync`, then call the user's `read_handler`/`write_handler` and read or
   write the value buffer, with no time limit. The `active` check at the start of `Invoke`
   does not cover that time, so `unregister` can return while a callback still uses the item.
3. **Registering again reuses the same memory.** `registerWindows` after `unregister` writes a
   fresh handler (reference count 1, `active = true`) over the one WinRT may still hold. A
   stale call then passes the `active` check, and a late `Release` of the old registration
   counts down the new one.

Also, a `registerWindows` that fails halfway calls `releaseWindows` on every service, which
calls `deactivate` on handler fields that were never initialised (`undefined`).

The client side had the same pattern and was changed on 2026-11-15 (`events.create`,
`events.drop`). These are the last handlers in fixed structs. No crash from this was seen on
hardware (B5 night 2026-11-15/16, 1427 connections to the Windows GATT server), but the soak
never calls `unregister`.

## Change

1. **Heap handlers, as on the client.** The four server handler types get the `destroy` field.
   `ServerCharacteristic` and `ServerDescriptor` hold `std.atomic.Value(?*Handler)`, default
   `null`, instead of the struct. `registerWindows` creates them with `events.create`. A
   handler that was created but whose `add_*` failed is dropped at once and its token stays 0.
   `events.drop` on `null` does nothing, so a half-done registration releases cleanly. A new
   registration always gets new objects, which fixes 3. The context stays the item: server
   items are not reused like the client's pool slots, so no item check is needed.
2. **Calls in flight are counted in the handler, in one place.** `makeVtbl.invoke` increments
   an `in_flight` counter on the handler, then checks `active`, and decrements after the
   callback returns. This store-then-load pairs with `unregister` storing `active = false` and
   then loading `in_flight`, so all four operations use `.seq_cst`. The counter lives in
   library memory, which WinRT keeps alive during `Invoke`. `onRead` and `onWrite` do not
   change. The client handlers get the same counter, unused for now.
3. **`unregister` waits, and fails honestly.** On Windows it works in three steps.
   - First, deactivate and `remove_*` every handler.
   - Then wait until every handler's `in_flight` is 0, using `std.Thread.Futex` rather than
     polling, bounded by 6 s.
   - Only then drop the handlers, release the characteristics and providers, and stop
     advertising.

   If the bound passes, `unregister` returns `error.RequestInFlight`. It keeps the handlers
   and leaves `is_registered` set, and the caller must not free the application. Calling
   `unregister` again waits again.
4. **No `unregister` from inside a request callback.** `invoke` sets a threadlocal flag while a
   callback runs. `unregister` returns `error.CalledFromCallback` when the flag is set,
   instead of waiting on itself.
5. **Document on `register`** that `GattApplication` must not move or be freed while
   registered, since WinRT and BlueZ keep pointers to it. That is the current contract; it is
   not written down.

Process exit without `unregister` leaks the handler pages until the OS reclaims them, which is
fine. `unregister` must not be called from `DllMain` or `atexit` (Futex wait under the loader
lock). The doc comment says so.

## Cost

- About 120 to 150 changed lines: `events.zig` (counter, flag and `destroy` for four types),
  `types.zig` (atomic fields, three-step release), `windows.zig` (create, error paths) and
  `app.zig` (`unregister` errors). One new piece of code, the bounded Futex wait.
- Two allocations per characteristic and per descriptor at registration. Each is a page from
  `page_allocator`, as on the client.
- `unregister` can block up to 6 s while a request runs, and gains two error values. Today it
  returns at once and leaves the danger to the caller.

## Not part of this change

- Data races between request callbacks (WinRT thread) and `setValue`/`notify` on the caller's
  thread. They exist today, on Linux too, and need their own design.

## Verification

Unit tests in `src/backend/windows/tests.zig`, with fake `Invoke` calls as for the client
handlers:
- A dropped handler is freed on its last `Release`, and an `Invoke` after the drop is silent.
- A slow callback that runs when `unregister` starts makes it wait, and `unregister` returns
  once the callback ends.
- A callback longer than the bound makes `unregister` return `error.RequestInFlight` and keep
  the handlers.
- `unregister` from inside a callback returns `error.CalledFromCallback`.
- A registration failure at the service, characteristic and descriptor level releases
  without touching uninitialised handlers.

Hardware (no new flag): the existing `--peripheral` run of `ble-hardware-check` unregisters
and registers its server once halfway through. A Linux central reading in a loop must read
and write the characteristic and the echo descriptor again afterwards. A debug log in `invoke`
for calls after a drop shows whether WinRT ever calls a removed handler (the open question
below). The B5 soak stays as it is.

## Open question

- Does WinRT call `Invoke` after `remove_*` has returned? Nobody has seen it. The change is
  needed either way because of problem 2; the debug log answers it.
