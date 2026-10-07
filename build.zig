const std = @import("std");

// Although this function looks imperative, it does not perform the build
// directly and instead it mutates the build graph (`b`) that will be then
// executed by an external runner. The functions in `std.Build` implement a DSL
// for defining build steps and express dependencies between them, allowing the
// build runner to parallelize the build automatically (and the cache system to
// know when a step doesn't need to be re-run).
pub fn build(b: *std.Build) void {
    // Standard target options allow the person running `zig build` to choose
    // what target to build for. Here we do not override the defaults, which
    // means any target is allowed, and the default is native. Other options
    // for restricting supported target set are available.
    const target = b.standardTargetOptions(.{});
    // Standard optimization options allow the person running `zig build` to select
    // between Debug, ReleaseSafe, ReleaseFast, and ReleaseSmall. Here we do not
    // set a preferred release mode, allowing the user to decide how to optimize.
    const optimize = b.standardOptimizeOption(.{});
    // It's also possible to define more custom flags to toggle optional features
    // of this build script using `b.option()`. All defined flags (including
    // target and optimize options) will be listed when running `zig build --help`
    // in this directory.

    // This creates a module, which represents a collection of source files alongside
    // some compilation options, such as optimization mode and linked system libraries.
    // Zig modules are the preferred way of making Zig code available to consumers.
    // addModule defines a module that we intend to make available for importing
    // to our consumers. We must give it a name because a Zig package can expose
    // multiple modules and consumers will need to be able to specify which
    // module they want to access.
    const mod = b.addModule("Zig_BLE", .{
        // The root source file is the "entry point" of this module. Users of
        // this module will only be able to access public declarations contained
        // in this file, which means that if you have declarations that you
        // intend to expose to consumers that were defined in other files part
        // of this module, you will have to make sure to re-export them from
        // the root file.
        .root_source_file = b.path("src/root.zig"),
        // Later on we'll use this module as the root module of a test executable
        // which requires us to specify a target.
        .target = target,
    });

    // Here we define an executable. An executable needs to have a root module
    // which needs to expose a `main` function. While we could add a main function
    // to the module defined above, it's sometimes preferable to split business
    // logic and the CLI into two separate modules.
    //
    // If your goal is to create a Zig library for others to use, consider if
    // it might benefit from also exposing a CLI tool. A parser library for a
    // data serialization format could also bundle a CLI syntax checker, for example.
    //
    // If instead your goal is to create an executable, consider if users might
    // be interested in also being able to embed the core functionality of your
    // program in their own executable in order to avoid the overhead involved in
    // subprocessing your CLI tool.
    //
    // If neither case applies to you, feel free to delete the declaration you
    // don't need and to put everything under a single module.
    const exe = b.addExecutable(.{
        .name = "Zig_BLE",
        .root_module = b.createModule(.{
            .root_source_file = b.path("src/main.zig"),
            .target = target,
            .optimize = optimize,
            .imports = &.{
                .{ .name = "Zig_BLE", .module = mod },
            },
        }),
    });

    const is_linux_target = target.result.os.tag == .linux;
    const default_link_dbus = false;
    const link_dbus = b.option(bool, "link-dbus", "Link system libdbus-1 (legacy C backend)") orelse default_link_dbus;

    if (link_dbus and is_linux_target) {
        mod.linkSystemLibrary("dbus-1", .{});
        mod.link_libc = true;
        exe.root_module.linkSystemLibrary("dbus-1", .{});
        exe.root_module.link_libc = true;
    }

    // This declares intent for the executable to be installed into the
    // install prefix when running `zig build` (i.e. when executing the default
    // step). By default the install prefix is `zig-out/` but can be overridden
    // by passing `--prefix` or `-p`.
    b.installArtifact(exe);

    // This creates a top level step. Top level steps have a name and can be
    // invoked by name when running `zig build` (e.g. `zig build run`).
    // This will evaluate the `run` step rather than the default step.
    // For a top level step to actually do something, it must depend on other
    // steps (e.g. a Run step, as we will see in a moment).
    const run_step = b.step("run", "Run the app");

    // This creates a RunArtifact step in the build graph. A RunArtifact step
    // invokes an executable compiled by Zig. Steps will only be executed by the
    // runner if invoked directly by the user (in the case of top level steps)
    // or if another step depends on it, so it's up to you to define when and
    // how this Run step will be executed. In our case we want to run it when
    // the user runs `zig build run`, so we create a dependency link.
    const run_cmd = b.addRunArtifact(exe);
    run_step.dependOn(&run_cmd.step);

    // By making the run step depend on the default step, it will be run from the
    // installation directory rather than directly from within the cache directory.
    run_cmd.step.dependOn(b.getInstallStep());

    // This allows the user to pass arguments to the application in the build
    // command itself, like this: `zig build run -- arg1 arg2 etc`
    if (b.args) |args| {
        run_cmd.addArgs(args);
    }

    // Creates an executable that will run `test` blocks from the provided module.
    // Here `mod` needs to define a target, which is why earlier we made sure to
    // set the releative field.
    const mod_tests = b.addTest(.{
        .root_module = mod,
    });

    // A run step that will run the test executable.
    const run_mod_tests = b.addRunArtifact(mod_tests);

    // Creates an executable that will run `test` blocks from the executable's
    // root module. Note that test executables only test one module at a time,
    // hence why we have to create two separate ones.
    const exe_tests = b.addTest(.{
        .root_module = exe.root_module,
    });

    // A run step that will run the second test executable.
    const run_exe_tests = b.addRunArtifact(exe_tests);

    const v1_e2e_tests = b.addTest(.{
        .root_module = b.createModule(.{
            .root_source_file = b.path("tests/test_v1_e2e_pipeline.zig"),
            .target = target,
            .optimize = optimize,
            .imports = &.{
                .{ .name = "Zig_BLE", .module = mod },
            },
        }),
    });
    const run_v1_e2e_tests = b.addRunArtifact(v1_e2e_tests);

    const v1_edgecase_tests = b.addTest(.{
        .root_module = b.createModule(.{
            .root_source_file = b.path("tests/test_v1_edgecases.zig"),
            .target = target,
            .optimize = optimize,
            .imports = &.{
                .{ .name = "Zig_BLE", .module = mod },
            },
        }),
    });
    const run_v1_edgecase_tests = b.addRunArtifact(v1_edgecase_tests);

    const v1_1_feature_tests = b.addTest(.{
        .root_module = b.createModule(.{
            .root_source_file = b.path("tests/test_v1_1_features.zig"),
            .target = target,
            .optimize = optimize,
            .imports = &.{
                .{ .name = "Zig_BLE", .module = mod },
            },
        }),
    });
    const run_v1_1_feature_tests = b.addRunArtifact(v1_1_feature_tests);

    // A top level step for running all tests. dependOn can be called multiple
    // times and since the two run steps do not depend on one another, this will
    // make the two of them run in parallel.
    const test_step = b.step("test", "Run tests");
    test_step.dependOn(&run_mod_tests.step);
    test_step.dependOn(&run_exe_tests.step);
    test_step.dependOn(&run_v1_e2e_tests.step);
    test_step.dependOn(&run_v1_edgecase_tests.step);
    test_step.dependOn(&run_v1_1_feature_tests.step);

    // ========================================================================
    // Standalone Examples (run-scanner, run-heart-rate)
    // ========================================================================
    const scanner_exe = b.addExecutable(.{
        .name = "ble-scanner",
        .root_module = b.createModule(.{
            .root_source_file = b.path("examples/scanner.zig"),
            .target = target,
            .optimize = optimize,
            .imports = &.{
                .{ .name = "Zig_BLE", .module = mod },
            },
        }),
    });
    if (link_dbus and is_linux_target) {
        scanner_exe.root_module.linkSystemLibrary("dbus-1", .{});
        scanner_exe.root_module.link_libc = true;
    }
    b.installArtifact(scanner_exe);

    const run_scanner_cmd = b.addRunArtifact(scanner_exe);
    const run_scanner_step = b.step("run-scanner", "Run the BLE terminal scanner example");
    run_scanner_step.dependOn(&run_scanner_cmd.step);

    const hrm_exe = b.addExecutable(.{
        .name = "ble-heart-rate",
        .root_module = b.createModule(.{
            .root_source_file = b.path("examples/heart_rate_peripheral.zig"),
            .target = target,
            .optimize = optimize,
            .imports = &.{
                .{ .name = "Zig_BLE", .module = mod },
            },
        }),
    });
    if (link_dbus and is_linux_target) {
        hrm_exe.root_module.linkSystemLibrary("dbus-1", .{});
        hrm_exe.root_module.link_libc = true;
    }
    b.installArtifact(hrm_exe);

    const run_hrm_cmd = b.addRunArtifact(hrm_exe);
    const run_hrm_step = b.step("run-heart-rate", "Run the BLE Heart Rate Peripheral simulator example");
    run_hrm_step.dependOn(&run_hrm_cmd.step);

    // ========================================================================
    // Apple iBeacon & Google Eddystone Broadcaster (run-beacon)
    // ========================================================================
    const beacon_exe = b.addExecutable(.{
        .name = "ble-beacon",
        .root_module = b.createModule(.{
            .root_source_file = b.path("examples/beacon_broadcaster.zig"),
            .target = target,
            .optimize = optimize,
            .imports = &.{
                .{ .name = "Zig_BLE", .module = mod },
            },
        }),
    });
    if (link_dbus and is_linux_target) {
        beacon_exe.root_module.linkSystemLibrary("dbus-1", .{});
        beacon_exe.root_module.link_libc = true;
    }
    b.installArtifact(beacon_exe);

    const run_beacon_cmd = b.addRunArtifact(beacon_exe);
    if (b.args) |args| {
        run_beacon_cmd.addArgs(args);
    }
    const run_beacon_step = b.step("run-beacon", "Run the Apple iBeacon & Google Eddystone Broadcaster example");
    run_beacon_step.dependOn(&run_beacon_cmd.step);

    // ========================================================================
    // Nordic UART Service (NUS) Serial Console (run-nus)
    // ========================================================================
    const nus_exe = b.addExecutable(.{
        .name = "ble-nus",
        .root_module = b.createModule(.{
            .root_source_file = b.path("examples/nus_terminal.zig"),
            .target = target,
            .optimize = optimize,
            .imports = &.{
                .{ .name = "Zig_BLE", .module = mod },
            },
        }),
    });
    if (link_dbus and is_linux_target) {
        nus_exe.root_module.linkSystemLibrary("dbus-1", .{});
        nus_exe.root_module.link_libc = true;
    }
    b.installArtifact(nus_exe);

    const run_nus_cmd = b.addRunArtifact(nus_exe);
    if (b.args) |args| {
        run_nus_cmd.addArgs(args);
    }
    const run_nus_step = b.step("run-nus", "Run the Nordic UART Service (NUS) serial console example");
    run_nus_step.dependOn(&run_nus_cmd.step);

    // ========================================================================
    // Real Hardware Windows Bluetooth Scanner (run-windows-scanner)
    // ========================================================================
    if (target.result.os.tag == .windows) {
        const win_scanner_exe = b.addExecutable(.{
            .name = "win-scanner",
            .root_module = b.createModule(.{
                .root_source_file = b.path("examples/windows_real_scanner.zig"),
                .target = target,
                .optimize = optimize,
                .imports = &.{
                    .{ .name = "Zig_BLE", .module = mod },
                },
            }),
        });
        b.installArtifact(win_scanner_exe);

        const run_win_scanner_cmd = b.addRunArtifact(win_scanner_exe);
        if (b.args) |args| {
            run_win_scanner_cmd.addArgs(args);
        }
        const run_win_scanner_step = b.step("run-windows-scanner", "Run the real hardware Windows Bluetooth scanner");
        run_win_scanner_step.dependOn(&run_win_scanner_cmd.step);

        const v1_live_exe = b.addExecutable(.{
            .name = "v1-live-verification",
            .root_module = b.createModule(.{
                .root_source_file = b.path("examples/v1_live_verification.zig"),
                .target = target,
                .optimize = optimize,
                .imports = &.{
                    .{ .name = "Zig_BLE", .module = mod },
                },
            }),
        });
        b.installArtifact(v1_live_exe);

        const run_v1_live_cmd = b.addRunArtifact(v1_live_exe);
        if (b.args) |args| {
            run_v1_live_cmd.addArgs(args);
        }
        const run_v1_live_step = b.step("run-v1-live", "Run the official Zig-BLE v1.0.0 Live Verification Suite");
        run_v1_live_step.dependOn(&run_v1_live_cmd.step);

        const probe_ble_exe = b.addExecutable(.{
            .name = "probe-ble",
            .root_module = b.createModule(.{
                .root_source_file = b.path("examples/probe_windows_ble_devices.zig"),
                .target = target,
                .optimize = optimize,
                .imports = &.{
                    .{ .name = "Zig_BLE", .module = mod },
                },
            }),
        });
        b.installArtifact(probe_ble_exe);

        const run_probe_ble_cmd = b.addRunArtifact(probe_ble_exe);
        if (b.args) |args| {
            run_probe_ble_cmd.addArgs(args);
        }
        const run_probe_ble_step = b.step("run-probe-ble", "Probe native Windows BLE device interfaces and GATT");
        run_probe_ble_step.dependOn(&run_probe_ble_cmd.step);

        const read_phone_gatt_exe = b.addExecutable(.{
            .name = "read-phone-gatt",
            .root_module = b.createModule(.{
                .root_source_file = b.path("examples/read_real_phone_gatt.zig"),
                .target = target,
                .optimize = optimize,
                .imports = &.{
                    .{ .name = "Zig_BLE", .module = mod },
                },
            }),
        });
        b.installArtifact(read_phone_gatt_exe);

        const run_read_phone_gatt_cmd = b.addRunArtifact(read_phone_gatt_exe);
        if (b.args) |args| {
            run_read_phone_gatt_cmd.addArgs(args);
        }
        const run_read_phone_gatt_step = b.step("run-read-phone-gatt", "Read real live GATT characteristics from S25 Ultra over the air");
        run_read_phone_gatt_step.dependOn(&run_read_phone_gatt_cmd.step);
    }

    // ========================================================================
    // L2CAP Connection-Oriented Channels Streamer (run-l2cap)
    // ========================================================================
    const l2cap_exe = b.addExecutable(.{
        .name = "ble-l2cap",
        .root_module = b.createModule(.{
            .root_source_file = b.path("examples/l2cap_stream.zig"),
            .target = target,
            .optimize = optimize,
            .imports = &.{
                .{ .name = "Zig_BLE", .module = mod },
            },
        }),
    });
    if (link_dbus and is_linux_target) {
        l2cap_exe.root_module.linkSystemLibrary("dbus-1", .{});
        l2cap_exe.root_module.link_libc = true;
    }
    b.installArtifact(l2cap_exe);

    const run_l2cap_cmd = b.addRunArtifact(l2cap_exe);
    if (b.args) |args| {
        run_l2cap_cmd.addArgs(args);
    }
    const run_l2cap_step = b.step("run-l2cap", "Run the L2CAP Connection-Oriented Channels (CoC) stream example");
    run_l2cap_step.dependOn(&run_l2cap_cmd.step);

    // ========================================================================
    // Zero-Daemon Raw HCI Scanner (run-raw-hci)
    // ========================================================================
    const raw_hci_exe = b.addExecutable(.{
        .name = "ble-raw-hci",
        .root_module = b.createModule(.{
            .root_source_file = b.path("examples/raw_hci_scanner.zig"),
            .target = target,
            .optimize = optimize,
            .imports = &.{
                .{ .name = "Zig_BLE", .module = mod },
            },
        }),
    });
    if (link_dbus and is_linux_target) {
        raw_hci_exe.root_module.linkSystemLibrary("dbus-1", .{});
        raw_hci_exe.root_module.link_libc = true;
    }
    b.installArtifact(raw_hci_exe);

    const run_raw_hci_cmd = b.addRunArtifact(raw_hci_exe);
    if (b.args) |args| {
        run_raw_hci_cmd.addArgs(args);
    }
    const run_raw_hci_step = b.step("run-raw-hci", "Run the Zero-Daemon Raw HCI Scanner example (no D-Bus, no bluetoothd)");
    run_raw_hci_step.dependOn(&run_raw_hci_cmd.step);

    // ========================================================================
    // Microbenchmark Suite (run-bench, bench)
    // ========================================================================
    const bench_exe = b.addExecutable(.{
        .name = "ble-benchmark",
        .root_module = b.createModule(.{
            .root_source_file = b.path("examples/benchmark.zig"),
            .target = target,
            .optimize = .ReleaseFast, // Default to ReleaseFast for realistic microbenchmarks
            .imports = &.{
                .{ .name = "Zig_BLE", .module = mod },
            },
        }),
    });
    if (link_dbus and is_linux_target) {
        bench_exe.root_module.link_libc = true;
    }
    b.installArtifact(bench_exe);

    const run_bench_cmd = b.addRunArtifact(bench_exe);
    const run_bench_step = b.step("run-bench", "Run the BLE microbenchmark suite");
    run_bench_step.dependOn(&run_bench_cmd.step);

    const bench_step = b.step("bench", "Alias for run-bench");
    bench_step.dependOn(&run_bench_cmd.step);

    // ========================================================================
    // Fuzz Testing Suite (zig build fuzz / test-fuzz)
    // ========================================================================
    const fuzz_exe = b.addExecutable(.{
        .name = "ble-fuzz",
        .root_module = b.createModule(.{
            .root_source_file = b.path("tests/fuzz_advertising.zig"),
            .target = target,
            .optimize = optimize,
            .imports = &.{
                .{ .name = "Zig_BLE", .module = mod },
            },
        }),
    });
    if (link_dbus and is_linux_target) {
        fuzz_exe.root_module.link_libc = true;
    }
    b.installArtifact(fuzz_exe);

    const run_fuzz_cmd = b.addRunArtifact(fuzz_exe);
    if (b.args) |args| {
        run_fuzz_cmd.addArgs(args);
    }
    const fuzz_step = b.step("fuzz", "Run the robust BLE Advertising fuzz testing suite (500k+ iterations)");
    fuzz_step.dependOn(&run_fuzz_cmd.step);

    const test_fuzz_step = b.step("test-fuzz", "Alias for fuzz");
    test_fuzz_step.dependOn(&run_fuzz_cmd.step);

    // ========================================================================
    // D-Bus Wire Fuzz Testing Suite (zig build fuzz-dbus)
    // ========================================================================
    const fuzz_dbus_exe = b.addExecutable(.{
        .name = "dbus-wire-fuzz",
        .root_module = b.createModule(.{
            .root_source_file = b.path("tests/fuzz_dbus_wire.zig"),
            .target = target,
            .optimize = optimize,
            .imports = &.{
                .{ .name = "Zig_BLE", .module = mod },
            },
        }),
    });
    b.installArtifact(fuzz_dbus_exe);

    const run_fuzz_dbus_cmd = b.addRunArtifact(fuzz_dbus_exe);
    if (b.args) |args| {
        run_fuzz_dbus_cmd.addArgs(args);
    }
    const fuzz_dbus_step = b.step("fuzz-dbus", "Run the pure-Zig D-Bus wire protocol fuzz testing suite (200k+ iterations)");
    fuzz_dbus_step.dependOn(&run_fuzz_dbus_cmd.step);

    // ========================================================================
    // Documentation (zig build docs)
    // ========================================================================
    const lib = b.addLibrary(.{
        .linkage = .static,
        .name = "zig_ble",
        .root_module = mod,
    });

    const install_docs = b.addInstallDirectory(.{
        .source_dir = lib.getEmittedDocs(),
        .install_dir = .prefix,
        .install_subdir = "docs",
    });
    const docs_step = b.step("docs", "Generate complete HTML documentation for Zig_BLE library");
    docs_step.dependOn(&install_docs.step);
}
