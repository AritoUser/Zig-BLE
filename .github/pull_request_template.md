## What and why

<!-- What does this change, and what problem does it solve? -->

## Do more with less

<!-- See docs/PHILOSOPHY.md. -->
- [ ] Nothing could be removed or simplified instead.
- [ ] No new dependency; any new allocation, thread, timer or option is bounded and explained.
- [ ] Backend changes ran on real hardware (which OS, which peer), or are marked experimental.

## Checks

- [ ] `zig build test`
- [ ] `zig build -Dtarget=x86_64-linux`
- [ ] `zig fmt --check .`
