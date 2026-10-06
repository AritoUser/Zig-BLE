# Contributing to Zig-BLE

Thank you for your interest in contributing to **Zig-BLE**! This document provides guidelines for contributing to ensure that the codebase remains robust, memory-safe, allocation-conscious, and maintainable.

---

## 1. Architectural Principles & Guarantees

Every contribution to Zig-BLE must strictly adhere to the project's core design principles:

1. **100% Pure Zig**:
   * No C compiler (`clang`, `gcc`, `MSVC`) required.
   * No runtime linking against `libc`, `libdbus-1`, `glib`, or external C dynamic libraries.
   * Cross-compilation must work seamlessly out-of-the-box (e.g., `zig build -Dtarget=x86_64-linux` or `aarch64-linux-musl`).

2. **Zero Dynamic Allocation on the Hot-Path (`no-alloc`)**:
   * Packet parsers, state machines, TLV iterators, and event dispatchers must never allocate on the heap (`malloc`, `page_allocator`, or dynamic `ArrayList`).
   * Use **borrow semantics**: Return structures whose string and byte slices point directly into the underlying receive buffers (`[]const u8`).
   * When buffers are needed, use bounded, fixed-capacity stack arrays or caller-supplied buffers.
   * Verify zero-allocation compliance using `std.testing.FailingAllocator` in unit tests.

3. **Strict Alignment & Endianness Safety**:
   * Never cast raw byte pointers directly to multi-byte integer pointers (`@ptrCast(*const u32, ...)`), as this causes hardware alignment traps (SIGBUS) on strict-alignment architectures (e.g., ARMv6, ARMv7, RISC-V).
   * Always use `std.mem.readInt(..., .little)` and `std.mem.writeInt(..., .little)` for protocol wire serialization.

4. **Deterministic Error Handling**:
   * All functions that can fail must return typed error sets. Avoid panics or unhandled errors in library code.

---

## 2. Development Setup

### Prerequisites
* **Zig Compiler**: Version **0.16.0+** installed and available in your `PATH`.
* **Git**: For version control.

### Building & Testing

```sh
# 1. Run all unit tests, E2E pipelines, and edge-case suites
zig build test

# 2. Run the 15-target microbenchmark suite
zig build run-bench

# 3. Validate cross-compilation for Linux (from Windows or macOS)
zig build -Dtarget=x86_64-linux

# 4. Run fuzz testing against malformed wire packets (500k iterations)
zig build fuzz

# 5. Build searchable HTML API documentation
zig build docs

# 6. Run live hardware tests (requires Bluetooth controller)
zig build run-v1-live
zig build run-windows-scanner
```

---

## 3. Code Style & Formatting

1. **Auto-Formatting**:
   All Zig code must be formatted using `zig fmt` before committing:
   ```sh
   zig fmt .
   ```

2. **Naming Conventions**:
   * **Types, Structs, Enums**: `PascalCase` (e.g., `UnifiedAdapter`, `AdvertisingReport`, `BackendVTable`).
   * **Functions, Methods**: `camelCase` (e.g., `readValue`, `startScan`, `processFragment`).
   * **Variables, Fields**: `snake_case` (e.g., `service_uuid`, `peer_address`, `head_index`).
   * **Constants**: `snake_case` or `UPPER_SNAKE_CASE` where standard (e.g., `company_id_apple`, `MAX_PREPARE_QUEUE`).

3. **Documentation**:
   * Exported functions, structs, and constants must include `///` doc-comments.
   * Doc-comments should clearly explain parameters, return values, errors, and any endianness or buffer lifetime invariants.

---

## 4. Pull Request Checklist

Before submitting a Pull Request, verify the following:

- [ ] All tests pass: `zig build test` (146/146 OK).
- [ ] Microbenchmarks execute cleanly without regressions: `zig build run-bench`.
- [ ] Code is formatted: `zig fmt .`.
- [ ] Zero heap allocations introduced on any protocol hot-path.
- [ ] Cross-compilation succeeds: `zig build -Dtarget=x86_64-linux`.
- [ ] HTML documentation builds cleanly: `zig build docs`.
- [ ] Commit message follows Conventional Commits (see below).

---

## 5. Commit Message Convention

We follow the [Conventional Commits](https://www.conventionalcommits.org/) specification:

* `feat:` A new feature or capability (e.g., `feat(hci): add BT 5.3 connection subrating commands`)
* `fix:` A bug fix (e.g., `fix(l2cap): handle zero-length continuation frame boundary`)
* `perf:` A performance optimization (e.g., `perf(dbus): eliminate allocator in Message.finalize`)
* `docs:` Documentation improvements (e.g., `docs: update protocol manual for v1.0.0 release`)
* `test:` Adding or updating tests (e.g., `test: add edge cases for prepare write queue cancel`)
* `refactor:` Code changes that neither fix bugs nor add features

---

## 6. License

By contributing to Zig-BLE, you agree that your contributions will be licensed under the project's [MIT License](LICENSE).
