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

The idea: take a Zig source file from the user (from an editor, file, network, REPL — wherever), run it through the Zig compiler embedded in the app, get a native binary for the current platform, load it into the same process, and execute it. The user code gets **full access to platform APIs** — UIKit on iOS, JNI/Activity on Android, WinAPI/Cocoa/X11 on desktop, threads, sockets, the file system.

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

Nothing to run yet. The planned CLI / application interface will look roughly like this:

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
- [ ] Skeleton Zig application with a `build.zig` project.
- [ ] Embed the Zig compiler as a static library, variant A (CLI-as-library), see plan §4.2.
- [ ] Linux: compile + `dlopen` + `dlsym` a minimal `entry()`.
- [ ] Windows: same thing via `LoadLibrary`.
- [ ] macOS: same thing via `dlopen`.
- [ ] Host bridge API (C ABI): `host_log`, `host_ui_alert`, `host_http_get` (see plan §10).

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

- is in a research stage, no working code yet;
- targets the author's personal devices, not distribution;
- uses an Apple developer certificate, which formally sits at the edge of the Apple Developer License Agreement (private key in the build). Justified by the project's nature (author's own devices, no third parties), but if you fork it — understand the risk to your own dev account;
- does not guarantee the approach will survive future iOS releases — Apple routinely tightens signature checks, and on-device signing may one day stop passing.

Everything here is at your own risk.
