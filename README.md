# zigbox

> 🇷🇺 Русская версия: **[README.ru.md](README.ru.md)**

An experimental project: an application that **dynamically compiles and runs Zig code at runtime** across all major platforms — Windows, Linux, macOS, Android, and (most interestingly) iOS without jailbreak.

Status: **early stage, research**. The goal is to figure out how feasible this really is and what comes out of it.

---

## 🤖 For AI agents reading this repository

**Before taking on any task, you must read `docs/zig-runtime-compilation-plan.md` in full, unless you've already read it earlier in this session.**

That document contains:

- the history of architectural decisions (so you don't re-litigate them);
- a detailed plan for each of the five target operating systems;
- a deep iOS section covering all the nuances of code signing, `amfid`, entitlements, and `dlopen`;
- a list of known pitfalls;
- links to key documentation (Apple Technotes, Zig internals, signing references);
- a glossary of terms.

Without that context, you will very likely propose an already-rejected approach (WASM, JIT, server-side compilation) and waste time. The plan is long, but it is the single source of truth for this project.

After reading it, you can move on to a specific milestone from section 9.9 of the plan, or to a task from the TODO list below.

---

## What this is

The idea: take a Zig source file from the user (from an editor, file, network, REPL — wherever), run it through the Zig compiler linked into the application, get a native binary for the current platform, load it, and execute it. The user code gets **full access to platform APIs** — UIKit on iOS, JNI/Activity on Android, WinAPI/Cocoa/X11 on desktop, threads, sockets, the file system.

Current implementation split:

- **Linux / macOS:** call upstream Zig's `mainArgs()` in-process.
- **Windows:** still link the compiler into `zigbox.exe`, but invoke it through a self-reexec path of the same binary (`__zigbox-zig`). This isolates upstream `std.process.exit(...)` call sites and also lets Zig's internal `lld-link` / `dlltool` / `cc` / `-cc1` tool dispatch keep working.
- **iOS target design:** still planned as pure in-process. The Windows subprocess workaround is a desktop-specific M1 stopgap, not the end-state architecture for iOS.

So the current desktop prototype does **not** depend on an external `zig.exe` at runtime, but Windows is not yet a strict "compile inside the same host process" implementation.

The main challenge is **iOS**. Apple formally prohibits running unsigned code, but signing is a cryptographic algorithm, not a privilege. If the application has a developer certificate's private key, it can sign on the device itself, and `amfid` will accept the resulting dylib. Details and limitations are in the plan.

This is a personal research project, **not intended for distribution through app stores** and making no claim to production quality.

---

## Platform support

| Platform | Approach | Status |
|---|---|---|
| Windows (x86_64) | Zig → DLL → `LoadLibrary` | 🔲 Not started |
| Linux (x86_64, aarch64) | Zig → SO → `dlopen` | 🔲 Not started |
| macOS (arm64 + x86_64) | Zig → dylib → `dlopen` | 🔲 Not started |
| Android (arm64, API 26+) | Zig → SO → `System.load` via JNI | 🔲 Not started |
| iOS (arm64, 16+) | Zig → dylib → on-device sign → `dlopen` | 🔲 Not started |

---

## Quick start

There is an early desktop prototype in the repository now. The eventual public API is still expected to look roughly like this:

```zig
// future usage example
const source = @embedFile("user_code.zig");
var runtime = try zigbox.Runtime.init(allocator, .{});
defer runtime.deinit();

const module = try runtime.compile(source);
const entry = try module.lookup("entry", fn () void);
entry();
```

---

## Rough TODO

The milestone numbering matches section 9.9 of the plan (iOS), plus separate steps for the other platforms.

### Phase 1 — desktop (proof of concept)
- [x] Skeleton Zig application with a `build.zig` project.
- [x] Embed the Zig compiler as a static library, variant A (CLI-as-library), see plan §4.2.
  - Upstream Zig is vendored as a git submodule under `deps/zig`.
  - `patches/zig-expose-lib.patch` adds a `libzig` static-library artifact to upstream's `build.zig` (one additive block, no edits to existing lines — survives upgrades cleanly).
  - `scripts/setup-zig-source.sh` clones, patches, and builds `libzig.a`.
  - Our `build.zig` links `libzig` into the host and imports upstream `src/main.zig` as a Zig module.
  - Linux/macOS currently call `mainArgs()` directly in-process.
  - Windows currently re-execs the same `zigbox.exe` in an internal `__zigbox-zig` mode to isolate upstream `std.process.exit(...)` and support Zig's internal multi-tool dispatch (`lld-link`, `dlltool`, `cc`, `-cc1`, ...).
- [ ] **M1.5** — replace `std.process.exit` call sites in the embedded compiler with recoverable errors so compile failures don't kill the host. Linux/macOS still need this for a robust pure in-process path; Windows currently uses self-reexec as a temporary desktop workaround.
- [ ] Linux: compile + `dlopen` + `dlsym` a minimal `entry()` — code ready, not yet verified end-to-end.
- [x] Windows: same thing via `LoadLibrary` — verified by `zig build smoke` on Windows/MSVC with LLVM-enabled libzig and `zigbox-host.lib`.
- [ ] macOS: same thing via `dlopen` — code ready, not yet verified.
- [x] Host bridge API (C ABI): `host_log`, `host_greet` in `src/bridge.zig`. `host_ui_alert` / `host_http_get` deferred to Phase 6.

Local verification of M1:

**Linux / macOS:**

```bash
# Important: the bootstrap zig must exactly match the selected upstream version.
# By default `supported` = the project's tested version (currently 0.14.0).

# One-time: clone upstream Zig, apply patch, build libzig.a (~minutes).
./scripts/setup-zig-source.sh

# Same thing, but auto-download a matching bootstrap Zig:
ZIG=auto ./scripts/setup-zig-source.sh

# Explicitly choose a supported release:
ZIG_TAG=0.14.0 ZIG=auto ./scripts/setup-zig-source.sh

# Pull the latest stable release from ziglang.org:
ZIG_TAG=latest-stable ZIG=auto ./scripts/setup-zig-source.sh

# Experimental: latest master snapshot.
ZIG_TAG=master ZIG=auto ./scripts/setup-zig-source.sh

# End-to-end compile + dlopen + call:
zig build smoke

# Or interactively with a different example:
zig build run -- examples/use_bridge.zig
```

**Windows (PowerShell):**

```powershell
# Important: the bootstrap zig must exactly match the selected upstream version.
# By default `supported` = the project's tested version (currently 0.14.0).

# Windows DLL emission currently requires libzig built with LLVM enabled.
# The exact LLVM paths are environment-specific.
.\scripts\setup-zig-source.ps1 `
  -Tag 0.14.0 `
  -Target x86_64-windows-msvc `
  -EnableLlvm `
  -ConfigH C:\path\to\zig\config.h `
  -SearchPrefix C:\path\to\llvm

# Same thing, but auto-download a matching bootstrap Zig:
.\scripts\setup-zig-source.ps1 `
  -Tag 0.14.0 `
  -Zig auto `
  -Target x86_64-windows-msvc `
  -EnableLlvm `
  -ConfigH C:\path\to\zig\config.h `
  -SearchPrefix C:\path\to\llvm

# Explicitly choose a supported release:
.\scripts\setup-zig-source.ps1 -Tag 0.14.0 -Zig auto

# Pull the latest stable release from ziglang.org:
.\scripts\setup-zig-source.ps1 -Tag latest-stable -Zig auto

# Experimental: latest master snapshot.
.\scripts\setup-zig-source.ps1 -Tag master -Zig auto

# The setup script prints the produced libzig path. For an LLVM-enabled
# Windows build you also need to tell zigbox's build about LLVM and zigcpp:
zig build smoke `
  -Dtarget=x86_64-windows-msvc `
  -Dembedded-zig-have-llvm=true `
  -Dembedded-zig-zigcpp=C:\path\to\zigcpp\zigcpp.lib `
  -Dlibzig="deps\zig\zig-out\lib\zig.lib" `
  --search-prefix C:\path\to\llvm
```

Known Windows caveats (tracked against M1.5/Phase 1):

- **Runtime path split.** Linux/macOS currently use `mainArgs()` directly in-process. Windows currently uses self-reexec of `zigbox.exe` in an internal `__zigbox-zig` mode. This keeps runtime independent from an external `zig.exe`, but it is still a subprocess workaround and not the final M1.5 architecture.
- **Windows host import library.** `build.zig` generates `zigbox-host.lib` with `zig dlltool`, and the embedded compiler links user DLLs against it automatically. This is the Windows replacement for the ELF/Mach-O `rdynamic` pattern.
- **Host must be built with the same ABI as libzig.** If upstream Zig on your machine builds libzig with `windows-msvc`, the host must also target `windows-msvc`; MinGW vs MSVC libs don't mix cleanly. `zig build -Dtarget=x86_64-windows-msvc` is the explicit form.
- **LLVM-enabled `libzig` is required for Windows DLL emission.** The upstream 0.14.0 COFF self-hosted backend cannot emit the needed dynamic-library output for this project yet, so Windows currently requires `-EnableLlvm` during setup plus `-Dembedded-zig-have-llvm=true` during `zig build`.

### Phase 2 — Android
- [ ] Gradle project with a JNI bridge to the Zig host.
- [ ] Build the Zig compiler for `aarch64-linux-android`.
- [ ] Kotlin `ZigRuntime` wrapper (example in plan §8.4).
- [ ] Verify on API 29+.

### Phase 3 — iOS M1: dlopen works
- [ ] iOS project in Xcode with Developer Mode enabled on the target device.
- [ ] Build a minimal test dylib ahead of time, bundle it with the app.
- [ ] Confirm `dlopen` / `dlsym` work against the bundled dylib.
- [ ] Sweep through `amfid` logs in Console.app.

### Phase 4 — iOS M2: on-device signing
- [ ] Integrate `ldid` (ProcursusTeam fork) as a static library.
- [ ] Alternative: start a custom signer based on the pseudocode in the plan (Appendix B) — only if ldid fails to build.
- [ ] Embed the dev cert in PKCS#12 format as an encrypted asset.
- [ ] Pipeline: bundled-unsigned-dylib → sign locally → re-signed dylib → `dlopen`.
- [ ] Byte-compare the resulting Mach-O against a `codesign`-signed one (for format debugging).

### Phase 5 — iOS M3: on-device compilation
- [ ] Wire up the Zig compiler for iOS.
- [ ] Build with `-fno-llvm` to reduce binary size.
- [ ] Pipeline: source → compile → unsigned dylib → sign → dlopen.
- [ ] Incremental compilation / caching.

### Phase 6 — full pipeline + UI
- [ ] UI for source input (iOS, Android, desktop).
- [ ] User-code examples: hello-world with alert, HTTP request, simple drawing.
- [ ] Measurements: compile time, binary size, memory usage.

### Phase 7 — optional extensions
- [ ] WASM fallback for iOS App Store (if publication is ever desired).
- [ ] Hot-reload on source changes.
- [ ] Syntax highlighting / LSP for the in-app editor.

---

## Help wanted & feedback

The author is **not a Zig expert** and makes no claim of expertise — this is a personal research experiment, a first attempt. If you have ideas, corrections, architectural critique, or see an obvious misunderstanding on my part — open an issue or a PR, I'll be happy to discuss.

Especially valuable feedback:

- hands-on experience with the Zig compiler's internal API (Compilation.zig, Module.zig);
- real cases of on-device code signing on modern iOS (18, 26);
- tips on using `ldid` against an iOS target;
- knowledge of amfid / library validation subtleties in current iOS;
- host-bridge architecture patterns for cross-platform scripting runtimes.

If you've tried something similar and **it didn't work** — that's also valuable, tell me where you got stuck.

---

## Development tooling

The project actively leans on AI agents. The following have been used or are currently used:

- **Claude Opus 4.7** — architectural discussions, deep technical reviews.
- **Claude Sonnet 4.6** — routine tasks, documentation, code review.
- **GPT-5.4 High** — cross-checking approaches, alternative viewpoints.
- **Gemini 3.1 Pro** — large-context work, documentation search.

If you're an AI agent working on this project in a new chat — one more reminder: **read `docs/zig-runtime-compilation-plan.md` first**. Any decisions made without it will be incorrect.

---

## Key documents

- **[docs/zig-runtime-compilation-plan.md](docs/zig-runtime-compilation-plan.md)** — the main project plan, read this first.
- [README.ru.md](README.ru.md) — Russian version of this file.
- README.md (this file) — quick intro in English.

---

## Disclaimer

This project:

- is in a research stage, with only an early desktop prototype so far;
- targets the author's personal devices, not distribution;
- uses an Apple developer certificate, which formally sits at the edge of the Apple Developer License Agreement (private key in the build). Justified by the project's nature (author's own devices, no third parties), but if you fork it — understand the risk to your own dev account;
- does not guarantee the approach will survive future iOS releases — Apple routinely tightens signature checks, and on-device signing may one day stop passing.

Everything here is at your own risk.
