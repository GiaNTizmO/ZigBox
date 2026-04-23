const std = @import("std");
const builtin = @import("builtin");
const ZigDevEnv = @import("deps/zig/src/dev.zig").Env;
const ZigValueInterpretMode = enum { direct, by_name };
const embedded_llvm_clang_libs = [_][]const u8{
    "clangFrontendTool",
    "clangCodeGen",
    "clangFrontend",
    "clangDriver",
    "clangSerialization",
    "clangSema",
    "clangStaticAnalyzerFrontend",
    "clangStaticAnalyzerCheckers",
    "clangStaticAnalyzerCore",
    "clangAnalysis",
    "clangASTMatchers",
    "clangAST",
    "clangParse",
    "clangSema",
    "clangAPINotes",
    "clangBasic",
    "clangEdit",
    "clangLex",
    "clangARCMigrate",
    "clangRewriteFrontend",
    "clangRewrite",
    "clangCrossTU",
    "clangIndex",
    "clangToolingCore",
    "clangExtractAPI",
    "clangSupport",
    "clangInstallAPI",
    "clangAST",
};
const embedded_llvm_lld_libs = [_][]const u8{
    "lldMinGW",
    "lldELF",
    "lldCOFF",
    "lldWasm",
    "lldMachO",
    "lldCommon",
};
const embedded_llvm_libs = [_][]const u8{
    "LLVMWindowsManifest",
    "LLVMXRay",
    "LLVMLibDriver",
    "LLVMDlltoolDriver",
    "LLVMTextAPIBinaryReader",
    "LLVMCoverage",
    "LLVMLineEditor",
    "LLVMSandboxIR",
    "LLVMXCoreDisassembler",
    "LLVMXCoreCodeGen",
    "LLVMXCoreDesc",
    "LLVMXCoreInfo",
    "LLVMX86TargetMCA",
    "LLVMX86Disassembler",
    "LLVMX86AsmParser",
    "LLVMX86CodeGen",
    "LLVMX86Desc",
    "LLVMX86Info",
    "LLVMWebAssemblyDisassembler",
    "LLVMWebAssemblyAsmParser",
    "LLVMWebAssemblyCodeGen",
    "LLVMWebAssemblyUtils",
    "LLVMWebAssemblyDesc",
    "LLVMWebAssemblyInfo",
    "LLVMVEDisassembler",
    "LLVMVEAsmParser",
    "LLVMVECodeGen",
    "LLVMVEDesc",
    "LLVMVEInfo",
    "LLVMSystemZDisassembler",
    "LLVMSystemZAsmParser",
    "LLVMSystemZCodeGen",
    "LLVMSystemZDesc",
    "LLVMSystemZInfo",
    "LLVMSparcDisassembler",
    "LLVMSparcAsmParser",
    "LLVMSparcCodeGen",
    "LLVMSparcDesc",
    "LLVMSparcInfo",
    "LLVMRISCVTargetMCA",
    "LLVMRISCVDisassembler",
    "LLVMRISCVAsmParser",
    "LLVMRISCVCodeGen",
    "LLVMRISCVDesc",
    "LLVMRISCVInfo",
    "LLVMLoongArchDisassembler",
    "LLVMLoongArchAsmParser",
    "LLVMLoongArchCodeGen",
    "LLVMLoongArchDesc",
    "LLVMLoongArchInfo",
    "LLVMPowerPCDisassembler",
    "LLVMPowerPCAsmParser",
    "LLVMPowerPCCodeGen",
    "LLVMPowerPCDesc",
    "LLVMPowerPCInfo",
    "LLVMNVPTXCodeGen",
    "LLVMNVPTXDesc",
    "LLVMNVPTXInfo",
    "LLVMMSP430Disassembler",
    "LLVMMSP430AsmParser",
    "LLVMMSP430CodeGen",
    "LLVMMSP430Desc",
    "LLVMMSP430Info",
    "LLVMMipsDisassembler",
    "LLVMMipsAsmParser",
    "LLVMMipsCodeGen",
    "LLVMMipsDesc",
    "LLVMMipsInfo",
    "LLVMLanaiDisassembler",
    "LLVMLanaiCodeGen",
    "LLVMLanaiAsmParser",
    "LLVMLanaiDesc",
    "LLVMLanaiInfo",
    "LLVMHexagonDisassembler",
    "LLVMHexagonCodeGen",
    "LLVMHexagonAsmParser",
    "LLVMHexagonDesc",
    "LLVMHexagonInfo",
    "LLVMBPFDisassembler",
    "LLVMBPFAsmParser",
    "LLVMBPFCodeGen",
    "LLVMBPFDesc",
    "LLVMBPFInfo",
    "LLVMAVRDisassembler",
    "LLVMAVRAsmParser",
    "LLVMAVRCodeGen",
    "LLVMAVRDesc",
    "LLVMAVRInfo",
    "LLVMARMDisassembler",
    "LLVMARMAsmParser",
    "LLVMARMCodeGen",
    "LLVMARMDesc",
    "LLVMARMUtils",
    "LLVMARMInfo",
    "LLVMAMDGPUTargetMCA",
    "LLVMAMDGPUDisassembler",
    "LLVMAMDGPUAsmParser",
    "LLVMAMDGPUCodeGen",
    "LLVMAMDGPUDesc",
    "LLVMAMDGPUUtils",
    "LLVMAMDGPUInfo",
    "LLVMAArch64Disassembler",
    "LLVMAArch64AsmParser",
    "LLVMAArch64CodeGen",
    "LLVMAArch64Desc",
    "LLVMAArch64Utils",
    "LLVMAArch64Info",
    "LLVMOrcDebugging",
    "LLVMOrcJIT",
    "LLVMWindowsDriver",
    "LLVMMCJIT",
    "LLVMJITLink",
    "LLVMInterpreter",
    "LLVMExecutionEngine",
    "LLVMRuntimeDyld",
    "LLVMOrcTargetProcess",
    "LLVMOrcShared",
    "LLVMDWP",
    "LLVMDebugInfoLogicalView",
    "LLVMDebugInfoGSYM",
    "LLVMOption",
    "LLVMObjectYAML",
    "LLVMObjCopy",
    "LLVMMCA",
    "LLVMMCDisassembler",
    "LLVMLTO",
    "LLVMPasses",
    "LLVMHipStdPar",
    "LLVMCFGuard",
    "LLVMCoroutines",
    "LLVMipo",
    "LLVMVectorize",
    "LLVMLinker",
    "LLVMInstrumentation",
    "LLVMFrontendOpenMP",
    "LLVMFrontendOffloading",
    "LLVMFrontendOpenACC",
    "LLVMFrontendHLSL",
    "LLVMFrontendDriver",
    "LLVMExtensions",
    "LLVMDWARFLinkerParallel",
    "LLVMDWARFLinkerClassic",
    "LLVMDWARFLinker",
    "LLVMCodeGenData",
    "LLVMGlobalISel",
    "LLVMMIRParser",
    "LLVMAsmPrinter",
    "LLVMSelectionDAG",
    "LLVMCodeGen",
    "LLVMTarget",
    "LLVMObjCARCOpts",
    "LLVMCodeGenTypes",
    "LLVMIRPrinter",
    "LLVMInterfaceStub",
    "LLVMFileCheck",
    "LLVMFuzzMutate",
    "LLVMScalarOpts",
    "LLVMInstCombine",
    "LLVMAggressiveInstCombine",
    "LLVMTransformUtils",
    "LLVMBitWriter",
    "LLVMAnalysis",
    "LLVMProfileData",
    "LLVMSymbolize",
    "LLVMDebugInfoBTF",
    "LLVMDebugInfoPDB",
    "LLVMDebugInfoMSF",
    "LLVMDebugInfoDWARF",
    "LLVMObject",
    "LLVMTextAPI",
    "LLVMMCParser",
    "LLVMIRReader",
    "LLVMAsmParser",
    "LLVMMC",
    "LLVMDebugInfoCodeView",
    "LLVMBitReader",
    "LLVMFuzzerCLI",
    "LLVMCore",
    "LLVMRemarks",
    "LLVMBitstreamReader",
    "LLVMBinaryFormat",
    "LLVMTargetParser",
    "LLVMSupport",
    "LLVMDemangle",
};

fn windowsDllToolMachine(arch: std.Target.Cpu.Arch) ?[]const u8 {
    return switch (arch) {
        .x86 => "i386",
        .x86_64 => "i386:x86-64",
        .arm => "arm",
        .aarch64 => "arm64",
        else => null,
    };
}

fn linkSystemLibraries(compile: *std.Build.Step.Compile, libs: []const []const u8) void {
    for (libs) |lib_name| {
        compile.linkSystemLibrary(lib_name);
    }
}

fn linkEmbeddedLlvmDeps(compile: *std.Build.Step.Compile) void {
    const target = compile.root_module.resolved_target.?.result;

    linkSystemLibraries(compile, &embedded_llvm_clang_libs);
    linkSystemLibraries(compile, &embedded_llvm_lld_libs);
    linkSystemLibraries(compile, &embedded_llvm_libs);
    switch (target.os.tag) {
        .linux => {
            compile.linkSystemLibrary("c++");
            compile.linkSystemLibrary("unwind");
        },
        .macos => {
            compile.linkSystemLibrary("c++");
        },
        .windows => {
            compile.linkSystemLibrary("ws2_32");
            compile.linkSystemLibrary("version");
            compile.linkSystemLibrary("uuid");
            compile.linkSystemLibrary("ole32");
            compile.linkSystemLibrary("advapi32");
            compile.linkSystemLibrary("ntdll");
            if (target.abi != .msvc) {
                compile.linkSystemLibrary("c++");
                compile.linkSystemLibrary("unwind");
            }
        },
        else => {},
    }
}

// ---------------------------------------------------------------
// Build plan
// ---------------------------------------------------------------
// zigbox embeds the Zig compiler as a static library and loads
// compiled user code via dlopen/LoadLibrary. Linux/macOS currently
// call upstream mainArgs() directly in-process. Windows keeps the
// compiler in this same binary, but re-execs zigbox.exe in an
// internal compiler mode until M1.5 removes upstream process exits.
//
// Pre-requisites (run `scripts/setup-zig-source.{sh,ps1}` once):
//   1. Clone upstream Zig into deps/zig. The setup scripts default
//      to the project's supported version (currently 0.14.0), but
//      also accept explicit tags plus `latest-stable` / `master`.
//   2. Apply patches/zig-expose-lib.patch, which adds an
//      `addStaticLibrary` artifact named "zig" to Zig's own
//      build.zig, sharing the executable's module graph.
//   3. Build libzig with a bootstrap Zig that exactly matches the
//      selected upstream version (`-Zig auto` / `ZIG=auto` can fetch
//      it automatically from ziglang.org).
//      This produces deps/zig/zig-out/lib/libzig.a (~150–300 MB
//      debug, ~40–80 MB release). Takes several minutes on a
//      cold cache, seconds incrementally.
//
// With that in place, `zig build` from the repo root links the
// compiler into the host and produces the `zigbox` binary.
// ---------------------------------------------------------------

pub fn build(b: *std.Build) void {
    const target = b.standardTargetOptions(.{});
    const optimize = b.standardOptimizeOption(.{});

    // Path to the pre-built Zig compiler static library. The file
    // name depends on target:
    //   - windows-msvc  → zig.lib
    //   - windows-gnu   → libzig.a
    //   - linux/macos   → libzig.a
    // setup-zig-source.{sh,ps1} prints the exact path at the end.
    // Override on the CLI:
    //   zig build -Dlibzig=C:/path/to/zig.lib
    //   zig build -Dlibzig=/abs/path/libzig.a
    const default_libzig: []const u8 = switch (target.result.os.tag) {
        .windows => switch (target.result.abi) {
            .msvc => "deps/zig/zig-out/lib/zig.lib",
            else => "deps/zig/zig-out/lib/libzig.a",
        },
        else => "deps/zig/zig-out/lib/libzig.a",
    };
    const libzig_path = b.option(
        []const u8,
        "libzig",
        "Path to the libzig static library produced by deps/zig",
    ) orelse default_libzig;

    // Path to Zig's own src/ directory, needed so we can
    // `@import` main.zig from the embedded compiler at Zig level.
    const zig_src_path = b.option(
        []const u8,
        "zig-src",
        "Path to upstream Zig's src/ directory (default: deps/zig/src)",
    ) orelse "deps/zig/src";

    // Escape hatch for unresolved symbols from libzig.a. Pass a
    // comma-separated list of extra system libraries, e.g.:
    //   -Dextra-libs=ole32,advapi32,ntdll
    // on Windows when the MSVC libzig references Win32 APIs we
    // haven't hard-coded below.
    const extra_libs_csv = b.option(
        []const u8,
        "extra-libs",
        "Comma-separated list of extra system libraries to link",
    ) orelse "";
    const embedded_zig_lib_dir = b.option(
        []const u8,
        "embedded-zig-lib-dir",
        "Path passed to the embedded compiler via --zig-lib-dir",
    ) orelse b.path("deps/zig/lib").getPath(b);
    const embedded_zig_have_llvm = b.option(
        bool,
        "embedded-zig-have-llvm",
        "Whether the linked libzig was built with -Denable-llvm",
    ) orelse false;
    const embedded_zig_zigcpp = b.option(
        []const u8,
        "embedded-zig-zigcpp",
        "Path to zigcpp static library produced by the upstream Zig CMake build",
    );

    // ---------------------------------------------------------------
    // Module that re-exports upstream Zig's main.zig so our
    // src/compiler.zig can call its public mainArgs function.
    // ---------------------------------------------------------------
    const zig_main_mod = b.addModule("zig_compiler", .{
        .root_source_file = .{ .cwd_relative = b.pathJoin(&.{ zig_src_path, "main.zig" }) },
        .target = target,
        .optimize = optimize,
    });
    const zig_build_options = b.addOptions();
    zig_build_options.addOption(u32, "mem_leak_frames", if (optimize == .Debug) 4 else 0);
    zig_build_options.addOption(bool, "skip_non_native", false);
    zig_build_options.addOption(bool, "have_llvm", embedded_zig_have_llvm);
    zig_build_options.addOption(bool, "llvm_has_m68k", false);
    zig_build_options.addOption(bool, "llvm_has_csky", false);
    zig_build_options.addOption(bool, "llvm_has_arc", false);
    zig_build_options.addOption(bool, "llvm_has_xtensa", false);
    zig_build_options.addOption(bool, "debug_gpa", false);
    zig_build_options.addOption([:0]const u8, "version", builtin.zig_version_string);
    zig_build_options.addOption(std.SemanticVersion, "semver", builtin.zig_version);
    zig_build_options.addOption(bool, "enable_debug_extensions", optimize == .Debug);
    zig_build_options.addOption(bool, "enable_logging", false);
    zig_build_options.addOption(bool, "enable_link_snapshots", false);
    zig_build_options.addOption(bool, "enable_tracy", false);
    zig_build_options.addOption(bool, "enable_tracy_callstack", false);
    zig_build_options.addOption(bool, "enable_tracy_allocation", false);
    zig_build_options.addOption(u32, "tracy_callstack_depth", 0);
    zig_build_options.addOption(bool, "value_tracing", false);
    zig_build_options.addOption(ZigDevEnv, "dev", .full);
    zig_build_options.addOption(ZigValueInterpretMode, "value_interpret_mode", .direct);
    zig_main_mod.addOptions("build_options", zig_build_options);

    const aro_mod = b.createModule(.{
        .root_source_file = .{ .cwd_relative = "deps/zig/lib/compiler/aro/aro.zig" },
        .target = target,
        .optimize = optimize,
    });
    const aro_translate_c_mod = b.createModule(.{
        .root_source_file = .{ .cwd_relative = "deps/zig/lib/compiler/aro_translate_c.zig" },
        .target = target,
        .optimize = optimize,
    });
    aro_translate_c_mod.addImport("aro", aro_mod);
    zig_main_mod.addImport("aro", aro_mod);
    zig_main_mod.addImport("aro_translate_c", aro_translate_c_mod);

    // ---------------------------------------------------------------
    // Host executable — the zigbox runtime.
    // ---------------------------------------------------------------
    const exe = b.addExecutable(.{
        .name = "zigbox",
        .root_source_file = b.path("src/main.zig"),
        .target = target,
        .optimize = optimize,
    });
    const app_build_options = b.addOptions();
    app_build_options.addOption([]const u8, "embedded_zig_lib_dir", embedded_zig_lib_dir);
    app_build_options.addOption(bool, "embedded_zig_have_llvm", embedded_zig_have_llvm);
    app_build_options.addOption(
        []const u8,
        "embedded_zig_windows_host_implib",
        if (target.result.os.tag == .windows) b.getInstallPath(.lib, "zigbox-host.lib") else "",
    );
    exe.root_module.addOptions("zigbox_build_options", app_build_options);

    // Link libc for dlopen/dlsym/dlclose and LoadLibrary shims.
    exe.linkLibC();

    // Export the host's dynamic symbols so user code (loaded via
    // dlopen) can resolve host_log, host_greet, etc. at runtime.
    exe.rdynamic = true;

    // Give our src/compiler.zig access to Zig's mainArgs.
    exe.root_module.addImport("zig_compiler", zig_main_mod);

    // Link the pre-built compiler static library. We attach it as
    // an object file rather than a Zig artifact because it's built
    // by an out-of-tree build script (see comment at top).
    exe.addObjectFile(.{ .cwd_relative = libzig_path });
    if (embedded_zig_have_llvm) {
        if (embedded_zig_zigcpp) |zigcpp_path| {
            exe.addObjectFile(.{ .cwd_relative = zigcpp_path });
        }
    }

    // LLVM / lld / the C++ runtime are transitively required by
    // libzig.a. The exact set depends on target — we make a
    // best-effort first guess and expose -Dextra-libs for the rest.
    if (embedded_zig_have_llvm) {
        linkEmbeddedLlvmDeps(exe);
    } else {
        switch (target.result.os.tag) {
            .linux => {
                exe.linkSystemLibrary("c++");
                exe.linkSystemLibrary("unwind");
            },
            .macos => {
                exe.linkSystemLibrary("c++");
            },
            .windows => {
                // MSVC target: the C/C++ runtime is pulled by linkLibC()
                // above plus the default MSVC libs. Common Win32
                // libraries touched by the non-LLVM libzig path are
                // added here.
                exe.linkSystemLibrary("ntdll");
                exe.linkSystemLibrary("advapi32");
                exe.linkSystemLibrary("version");
                exe.linkSystemLibrary("ole32");
                exe.linkSystemLibrary("uuid");
                if (target.result.abi != .msvc) {
                    exe.linkSystemLibrary("c++");
                    exe.linkSystemLibrary("unwind");
                }
            },
            else => {},
        }
    }

    // Apply any user-supplied extras (comma-separated).
    if (extra_libs_csv.len > 0) {
        var it = std.mem.splitScalar(u8, extra_libs_csv, ',');
        while (it.next()) |lib| {
            const trimmed = std.mem.trim(u8, lib, " \t");
            if (trimmed.len == 0) continue;
            exe.linkSystemLibrary(trimmed);
        }
    }

    if (target.result.os.tag == .windows) {
        const dlltool_machine = windowsDllToolMachine(target.result.cpu.arch) orelse
            @panic("unsupported Windows target architecture for zigbox host import library");
        const write_files = b.addWriteFiles();
        const host_def = write_files.add(
            "zigbox-host.def",
            \\LIBRARY zigbox.exe
            \\EXPORTS
            \\    host_log
            \\    host_greet
            \\
        );
        const host_implib_cmd = b.addSystemCommand(&.{
            b.graph.zig_exe,
            "dlltool",
            "-m",
            dlltool_machine,
            "-D",
            "zigbox.exe",
            "-d",
        });
        host_implib_cmd.addFileArg(host_def);
        host_implib_cmd.addArg("-l");
        const host_implib = host_implib_cmd.addOutputFileArg("zigbox-host.lib");
        const install_host_implib = b.addInstallLibFile(host_implib, "zigbox-host.lib");
        b.getInstallStep().dependOn(&install_host_implib.step);
    }

    b.installArtifact(exe);

    // `zig build run -- examples/hello.zig [entry_symbol]`
    const run_cmd = b.addRunArtifact(exe);
    run_cmd.step.dependOn(b.getInstallStep());
    if (b.args) |args| run_cmd.addArgs(args);

    const run_step = b.step("run", "Run the zigbox host (pass args after `--`)");
    run_step.dependOn(&run_cmd.step);

    // ---------------------------------------------------------------
    // Tests — host-only, no compiler dependency.
    //
    // Rooted at src/tests.zig rather than src/main.zig so that
    // neither runtime.zig nor compiler.zig (which require libzig.a)
    // are pulled in during analysis. This lets `zig build test`
    // run cleanly before setup-zig-source.sh is executed.
    // ---------------------------------------------------------------
    const tests = b.addTest(.{
        .root_source_file = b.path("src/tests.zig"),
        .target = target,
        .optimize = optimize,
    });
    tests.linkLibC();
    const run_tests = b.addRunArtifact(tests);
    const test_step = b.step("test", "Run unit tests");
    test_step.dependOn(&run_tests.step);

    // ---------------------------------------------------------------
    // Smoke test: end-to-end compile + load + call of examples/hello.zig
    // ---------------------------------------------------------------
    const smoke = b.addRunArtifact(exe);
    smoke.step.dependOn(b.getInstallStep());
    smoke.addArg("examples/hello.zig");
    const smoke_step = b.step("smoke", "End-to-end M1 smoke test (hello example)");
    smoke_step.dependOn(&smoke.step);
}
