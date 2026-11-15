# Do more with less

This is the rule Zig-BLE is built by. When two designs work, the one with less in it wins:
fewer dependencies, fewer bytes, fewer lines, fewer features, fewer claims. What stays has to
earn its place, and it has to be proven.

The rule is not about being small for its own sake. Everything a library carries is something
a user has to build, trust, debug and keep working. Less of it means less to go wrong.

## What it means here

**Fewer dependencies.** Pure Zig, no C toolchain, no `libc`, no `libdbus`. Zig-BLE talks to
BlueZ over its own D-Bus wire client and to WinRT through its own bindings. A new dependency
needs a reason that outweighs every build it complicates.

**Less memory, and a known amount.** Parsers take no allocator. Backends use fixed-size pools
for devices, characteristics and subscriptions. A bound that is known at compile time beats a
buffer that grows. Where something must live on the heap, it is because another party decides
its lifetime (WinRT keeps event handlers as long as it likes), and the allocation sits off the
hot path, one per subscription or connection, never per packet.

**Less code of our own.** The operating system already has a tested Bluetooth stack. Zig-BLE
uses WinRT and BlueZ for connections, encryption and pairing instead of writing its own, and
spends its code on what those stacks leave open: a common API, correct lifetimes, honest
errors. Deleting code is progress. A fix that removes a special case is better than one that
adds a second.

**Less work per operation.** Do not ask the radio twice for what is already known: one
discovery per link, the cache for the rest. Do not poll what can be awaited. Do not copy what
can be borrowed: parsers return slices into the receive buffer.

**A smaller API.** One way to do a thing. A new function, option or flag is a promise to keep
it working on every backend. If it cannot be tested on real hardware, it waits.

**Fewer claims, all of them backed.** A feature is "done" when it ran on real hardware, in
both directions where that applies, and the run is written down (see
[HARDWARE_TESTS.md](HARDWARE_TESTS.md) and [V2_BLOCKERS.md](V2_BLOCKERS.md)). A tested 80 %
is worth more than an untested 100 %. Features that are not there yet are marked as
experimental, not described as if they worked.

**Fewer words.** Documentation says what a thing does, what it costs and where it stops. A
short page that is true beats a long one that has to be read twice.

## Using it to decide

Before adding something, ask:

1. Can this be solved by removing or simplifying something instead?
2. Does it add a dependency, an allocation, a thread, a timer or a configuration option? Then
   the benefit must be worth that cost, and the cost must be bounded.
3. Does the OS stack already do it? Then use that.
4. Will it be verified on real hardware? If not, does it have to ship now?
5. After the change, is there less to understand than before, or at least not more?

A pull request that does the same with less is always welcome.
