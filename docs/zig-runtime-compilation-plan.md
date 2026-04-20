# Dynamic Zig Compilation & Execution — Cross-Platform Technical Plan

> 🇷🇺 Russian version: **[zig-runtime-compilation-plan.ru.md](zig-runtime-compilation-plan.ru.md)**

**Document status:** technical plan with implementation-level detail.
**Date:** April 2026.
**Target Zig versions:** 0.14.x / 0.15.x (as of this writing).
**Project character:** research, personal. Not intended for mass distribution. App Store not required. No jailbreak is used. The author accepts embedding the developer private key into their own build for deployment to their own devices.

---

## 0. How to read this document

This document was written as **context for future chat sessions**. It collects:

1. Problem statement and history of decisions (so they are not re-litigated).
2. Solution architecture for each OS separately.
3. A deep iOS section (the hardest platform).
4. Links to key documentation.
5. A list of known pitfalls.

When opening this file in a new chat, tell the assistant: "Read this document fully, it's the project plan." After that, move directly to a specific implementation step.

---

## 1. Problem statement

Build an application that:

- **Accepts Zig source code at runtime** (from the user, from a file, from the network, from a DSL editor inside the application — doesn't matter).
- **Compiles it** into the target platform's native executable format.
- **Executes the result** with full access to platform APIs (UIKit/UIApplication on iOS, Activity/JNI on Android, Win32/Cocoa/X11 on desktop), threads, network, file system, hardware acceleration.
- **Works on six targets:** Windows x86_64, Linux x86_64, macOS arm64 + x86_64, Android arm64 (+ armv7 optionally), iOS arm64.

Not required: support for every possible device, app-store compatibility, restricting the "safe" subset of Zig. This is a personal research project running on controlled devices.

---

## 2. History of decisions

This section explains **why** the architecture looks the way it does. In a new chat it will save you time on re-debating.

### 2.1. Approaches considered

| Approach | Decision | Reason |
|---|---|---|
| Subprocess `zig build-exe` + run the binary | Use on Win/Lin/Mac/Android, **reject for iOS** | iOS sandbox blocks `execve` of arbitrary binaries |
| WASM + interpreter (wasm3 / JavaScriptCore) | **Reject as primary path** | No direct UIKit/OS API access, requires manual bridge functions for every call |
| JIT in-process (MAP_JIT + Zig → memory → execute) | **Reject** | On iOS requires JIT entitlement + debugger attach (JitStreamer); bad UX; fragile |
| TrollStore bypass | **Reject** | Only for old iOS (<17); no guarantee |
| Server-side compile + `dlopen` of signed dylib | **Reject** | Network dependency, key storage concerns, latency |
| **On-device compile + on-device sign + `dlopen`** | **CHOSEN PATH FOR iOS** | Everything local, native performance, UIKit directly available |

### 2.2. Why on-device signing works

This is the critical point, briefly:

- `amfid` (AppleMobileFileIntegrity daemon) verifies signatures at `dlopen` time, but it **does not care where the signature was created**. It checks hash correctness + certificate chain to the Apple root + team ID match. All of that can be done on the device itself, given a private key.
- Signing is a deterministic cryptographic operation. The signature bytes produced on an iPhone are indistinguishable from ones produced on a Mac via `codesign`.
- Swift Playgrounds (the only Apple app doing on-device compile+sign+run) uses a private entitlement, but apparently for access to private compiler SPIs rather than for `dlopen` as such. For our scenario, no private entitlement is needed — we bring our own Zig compiler.

### 2.3. Risks accepted

- **Private key in the build**: technically a breach of the Apple Developer Program License Agreement. Justified for local research on the author's own devices.
- **7-day re-provisioning** with a free Apple ID, or **1-year** with a paid Developer Program. After cert expiry, `amfid` rejects dylibs signed with it.
- **Limited device set** (UDIDs must be in the provisioning profile).

---

## 3. Overall architecture

In all targets the application has the same logical structure:

```
┌─────────────────────────────────────────────┐
│ Host App (UI, lifecycle, platform glue)     │
│  - Swift/UIKit (iOS)                        │
│  - Kotlin/Activity (Android)                │
│  - Zig/native (desktop)                     │
└──────────────┬──────────────────────────────┘
               │ Bridge API (C ABI)
┌──────────────▼──────────────────────────────┐
│ Embedded Zig Compiler (library form)        │
│  - Parse + semantics + codegen              │
│  - Emit: Mach-O / ELF / COFF / WASM         │
└──────────────┬──────────────────────────────┘
               │ emit bytes
┌──────────────▼──────────────────────────────┐
│ Platform Loader                             │
│  - Desktop/Android: file on disk + dlopen   │
│  - iOS: sign locally + dlopen               │
└──────────────┬──────────────────────────────┘
               │ function pointer
┌──────────────▼──────────────────────────────┐
│ Generated user code (native)                │
│  full access to OS API, memory, etc.        │
└─────────────────────────────────────────────┘
```

Key principle: **the compiler and the loader are libraries** linked into your application. No subprocesses anywhere, except on desktop/Android if you want them.

---

## 4. Embedding the Zig compiler as a library

This part is shared across all platforms.

### 4.1. Current state of Zig

As of Zig 0.14+, the compiler is fully self-hosted (written in Zig, the C++ backend removed). Source: `github.com/ziglang/zig`. Key modules:

- `src/main.zig` — CLI entry point.
- `src/Compilation.zig` — top-level compilation orchestrator.
- `src/Module.zig` — module and type model.
- `src/Sema.zig` — semantic analysis.
- `src/codegen/` — backends (llvm, x86_64, aarch64, wasm, c).
- `src/link/` — linkers (Elf, MachO, Coff, Wasm).

There is **no stable public library API** for Zig. Internal structures may change between minor versions.

### 4.2. Embedding strategy

Two options:

**Option A: CLI-as-library.** Build `zig` as a static library with an entry point `zig_main(argc, argv)` and call it with an argv such as `["zig", "build-lib", "-dynamic", "-target", "aarch64-ios", "-O", "ReleaseFast", "input.zig", "-femit-bin=output.dylib"]`. This runs the same logic as the console `zig`.

Caveats:
- Patch `src/main.zig` so that `std.process.exit` is not called — otherwise it kills the whole application.
- Redirect stdout/stderr via `dup2` onto your own file descriptors for logging.
- File system access uses normal syscalls — on iOS that's the app sandbox, so use paths inside `Documents/` or `tmp/`.
- Pin a specific Zig version and don't upgrade until you've vetted the diff.

**Option B: Direct API.** Import `Compilation.zig` directly, build a `Compilation` object, configure it, and call `.update()`. Cleaner and lower overhead, but **maximally coupled to the compiler's internal version** — any Zig update risks breaking everything.

**Recommendation:** start with option A. Move to B only if you have specific needs (e.g. intercepting comptime internals).

### 4.3. Build

In the main app's `build.zig`:

```zig
const zig_src = b.dependency("zig_compiler", .{
    .target = target,
    .optimize = .ReleaseFast,
});
const zig_lib = zig_src.artifact("zig_lib");

const exe = b.addExecutable(.{
    .name = "dyn-zig-host",
    .target = target,
    .optimize = optimize,
});
exe.linkLibrary(zig_lib);
```

Resulting binary size: roughly 40–90 MB depending on target and backend (LLVM adds the most). For iOS you can disable the LLVM backend and use self-hosted (`-fno-llvm`), which brings it down to 15–25 MB at the cost of some optimization quality.

### 4.4. Calling from the host app

With a C ABI:

```c
extern int zig_compile(int argc, const char **argv);
```

From Swift (iOS/macOS):

```swift
let args = ["zig", "build-lib", "-dynamic", "-target", "aarch64-ios",
            inputPath, "-femit-bin=" + outputPath]
let cArgs = args.map { strdup($0) }
let result = zig_compile(Int32(args.count), cArgs.map { UnsafePointer($0) })
cArgs.forEach { free($0) }
```

From Kotlin (Android) — via JNI, after `System.loadLibrary("dynzig")`.

---

## 5. Windows — detailed plan

### 5.1. Targets
- `x86_64-windows-msvc` (primary).
- Optionally: `aarch64-windows` for Surface Pro X.

### 5.2. Execution flow

1. App written in Zig (optional GUI: WinAPI / GDI+, or plain console).
2. User supplies Zig source (to a file or TextBox).
3. Host calls `zig_compile` with `-target x86_64-windows -dynamic -fPIC`.
4. Output: `generated.dll` under `%APPDATA%\DynZig\` or a temp folder.
5. Host calls `LoadLibraryW(L"generated.dll")` → `GetProcAddress(hmod, "entry")` → invoke.

### 5.3. Windows specifics

- **DLL export:** user code must export a symbol. In Zig: `export fn entry() callconv(.C) void { ... }`.
- **Search path:** call `SetDllDirectoryW` before `LoadLibrary`, or use an absolute path, to avoid pulling in dependencies from unknown places.
- **Antivirus:** Windows Defender may heuristically scan freshly-created DLLs. Usually not a blocker on a dev machine, but end users may see delays. Solved by a Code Signing certificate (EV preferred).
- **Unload:** `FreeLibrary(hmod)`. Note that if the DLL leaves a thread running, the process will hang.

### 5.4. Alternative: `.exe` as a separate process

If tight host integration isn't needed:

```zig
var child = std.process.Child.init(&.{exe_path}, allocator);
try child.spawn();
const term = try child.wait();
```

Easier to debug (crash in user code doesn't kill the host), but no shared state.

### 5.5. Docs
- MSDN: `LoadLibrary`, `GetProcAddress`, `FreeLibrary`.
- Zig MSVC cross-compilation: `ziglang.org/learn/overview/` → cross-compilation.

---

## 6. Linux — detailed plan

### 6.1. Targets
- `x86_64-linux-gnu` — primary.
- `x86_64-linux-musl` — for fully static builds.
- `aarch64-linux-gnu` — for ARM servers / Raspberry Pi.

### 6.2. Execution flow

Analogous to Windows, but with POSIX tooling:

1. Compile → `/tmp/dynzig-XXXXXX/generated.so`.
2. `dlopen("/tmp/.../generated.so", RTLD_NOW | RTLD_LOCAL)` → `dlsym(h, "entry")`.
3. Call.

### 6.3. Linux specifics

- **`glibc` vs `musl`:** user code and host must use the same libc. Easiest is to build both with the same `-target`.
- **`noexec` on `/tmp`:** some distros mount `/tmp` with `noexec`. Workaround — write to `~/.cache/dynzig/` or use `memfd_create` + `fdlopen` (glibc 2.26+).
- **SELinux / AppArmor:** on hardened systems may block `dlopen` from user-writable paths. Usually not an issue on a dev box.
- **RPATH:** if user code depends on other .so files, you need to specify them in rpath at link time, or have the host `dlopen` them first.

### 6.4. `memfd_create` trick (optional)

Lets you skip writing a file to disk:

```zig
const fd = std.os.linux.memfd_create("dynzig", 0);
try std.posix.write(fd, compiled_bytes);
const path = try std.fmt.allocPrint(alloc, "/proc/self/fd/{d}", .{fd});
const handle = std.c.dlopen(path.ptr, RTLD_NOW);
```

Pros: nothing lands on disk. Cons: glibc-specific; musl needs a different approach.

### 6.5. Docs
- `man 3 dlopen`, `man 3 dlsym`, `man 2 memfd_create`.
- Linux ELF specification (to understand the format Zig emits).

---

## 7. macOS — detailed plan

### 7.1. Targets
- `aarch64-macos` — Apple Silicon.
- `x86_64-macos` — Intel (for compatibility).
- Universal Binary (fat Mach-O) — optional.

### 7.2. Execution flow

1. Compile → `~/Library/Application Support/DynZig/generated.dylib`.
2. If the application is distributed:
   - **Without notarization, signed with Developer ID**: you need the entitlement `com.apple.security.cs.disable-library-validation` in the hardened runtime, otherwise `dlopen` rejects dylibs with a foreign team ID. If you sign the dylib with your own team ID, not needed.
   - **For personal use without Gatekeeper**: "just works", but new macOS (14+) may show a Gatekeeper prompt on first launch.
3. `dlopen` → `dlsym` → call.

### 7.3. macOS specifics

- **Hardened runtime:** if the app is signed with it (mandatory for notarization), you need entitlements `com.apple.security.cs.allow-unsigned-executable-memory` (if you use JIT — we do NOT) or `com.apple.security.cs.disable-library-validation` to load dylibs signed by a different team ID.
- **For Zig-compiled dylibs:** sign them with the same team ID as the main app — library validation passes without extra entitlements.
- **Sign command:** `codesign --sign "Developer ID Application: Your Name" --timestamp --options runtime generated.dylib`.
- **Mac App Store** — not applicable; you stated you don't need stores.
- **No JIT needed**: we compile to a file, not to memory. Much simpler Code Signing.

### 7.4. The only difference from iOS

Gatekeeper on macOS checks signatures **on first launch**, then caches. `amfid` exists on macOS too but is much softer — it trusts any Developer ID + notarization. On **macOS for personal use you can even skip signing** dylibs if Gatekeeper is disabled or SIP is in permissive mode. This makes the macOS target simpler than iOS.

### 7.5. Docs
- Apple TN3125 (Inside Code Signing: hashes): `developer.apple.com/documentation/technotes/tn3125-inside-code-signing-hashes`.
- `man dlopen` (system manual, Darwin).
- `man codesign`.

---

## 8. Android — detailed plan

### 8.1. Targets
- `aarch64-linux-android` — primary, all modern devices.
- `x86_64-linux-android` — for emulators.
- `armv7a-linux-androideabi` — only for very old device support.

Minimum Android API: 26 (Oreo) or 29 (10). API 29+ is preferred — more modern SELinux policies, easier handling of executable files.

### 8.2. Execution flow

1. Host in Kotlin or Java + a C++ JNI wrapper.
2. Zig compiler embedded as a `.so` and loaded via `System.loadLibrary("dynzig_host")` at app start.
3. User source: received in the UI, saved to `context.filesDir + "/src.zig"`.
4. Compile: JNI bridge calls `zig_compile(...)` via C ABI, output → `context.filesDir + "/generated.so"`.
5. Load: `System.load("/data/data/<pkg>/files/generated.so")` or `dlopen` via JNI.
6. Call: `dlsym` + function pointer via JNI.

### 8.3. Android specifics

- **Android 10+ restrictions:** from API 29, executing files extracted from the APK directly is forbidden. But files **created in `getFilesDir()` by the app itself** can be executed and loaded. The Zig compiler must write there.
- **W^X:** Android does not require JIT entitlements because we don't JIT — we write a file and then load it.
- **SELinux:** the `u:object_r:app_data_file:s0` domain allows execute by the app's own UID. Usually not an issue.
- **Linker:** Android uses its own bionic linker, some glibc constructs (`ifunc`, complex TLS models) are unsupported. Zig must be compiled with `-target aarch64-linux-android` and the proper API level.
- **NDK compatibility:** if user code wants to `#include <jni.h>` or call Android SDK methods — you need JNI bindings. Zig doesn't ship these formally, but you can import NDK headers via `@cImport`.
- **App Bundle (AAB):** if you plan to publish on Google Play — the Play Store **does allow** `dlopen` of dynamically compiled code, unlike Apple. Publication isn't needed in this project, but the option is open.

### 8.4. Kotlin bridge example

```kotlin
class ZigRuntime(private val filesDir: File) {
    init { System.loadLibrary("dynzig_host") }

    external fun zigCompile(args: Array<String>): Int
    external fun zigDlopen(path: String): Long
    external fun zigDlsym(handle: Long, name: String): Long
    external fun zigCallVoid(funcPtr: Long)

    fun runUserCode(source: String): Int {
        val src = File(filesDir, "user.zig").apply { writeText(source) }
        val out = File(filesDir, "generated.so")
        val rc = zigCompile(arrayOf(
            "zig", "build-lib", "-dynamic",
            "-target", "aarch64-linux-android",
            "-O", "ReleaseFast",
            src.absolutePath,
            "-femit-bin=" + out.absolutePath
        ))
        if (rc != 0) return rc
        val h = zigDlopen(out.absolutePath)
        if (h == 0L) return -1
        val f = zigDlsym(h, "entry")
        if (f == 0L) return -2
        zigCallVoid(f)
        return 0
    }
}
```

### 8.5. Docs
- Android NDK: `developer.android.com/ndk`.
- Android dynamic linker limitations: `android.googlesource.com/platform/bionic/+/master/android-changes-for-ndk-developers.md`.
- Zig cross-compilation to Android: `ziglang.org` (targets section).

---

## 9. iOS — detailed plan (the project's core challenge)

### 9.1. iOS ground rules

iOS differs from the other platforms in that:

1. Any executable Mach-O code — main app or dylib — is checked by the kernel subsystem `amfid` for signature validity.
2. `fork()` + `execve()` of arbitrary binaries is blocked by the sandbox entirely.
3. Code must be signed by a certificate chaining to Apple's root CA.
4. Provisioning: the device must be in the UDID list of the provisioning profile.
5. Developer Mode (iOS 16+) must be enabled.

But — and this is the key point — **signing is performed by whoever has the private key**. The iOS kernel verifies hash math and trusts the certificate chain. **It does not know or care which process created the signature.** So if a process inside an iOS app has access to the private key, it can produce signatures that `amfid` will accept.

### 9.2. Required components

| Component | Purpose | Source |
|---|---|---|
| Apple Developer Account | To issue certificates and provisioning profiles | `developer.apple.com` ($99/year paid, or free Apple ID with a 7-day limit) |
| iOS Development Certificate (.cer + private key .p12) | Sign app and dylibs | Xcode → Preferences → Accounts → Manage Certificates, or Keychain Access → export |
| Provisioning Profile (.mobileprovision) | Binds team ID + UDIDs + entitlements | Apple Developer portal, automatic via Xcode |
| Device UDID | Register a device in the profile | Xcode → Window → Devices, or `idevice_id` |
| Developer Mode enabled | Required in iOS 16+ to run dev builds | Settings → Privacy & Security → Developer Mode |
| Zig compiler as library | On-device compilation | Custom build from `github.com/ziglang/zig`, see §4 |
| Signing library | On-device dylib signing | `ldid` (ProcursusTeam fork) or custom implementation |

### 9.3. App architecture

```
┌──────────────────────────────────────────────┐
│ iOS App Bundle (.ipa)                        │
│  ├── Info.plist                              │
│  ├── embedded.mobileprovision                │
│  ├── DynZigHost (main Mach-O)                │
│  │    ├── Swift/ObjC UI layer                │
│  │    ├── Zig compiler (linked as .a)        │
│  │    ├── ldid signing code (linked as .a)   │
│  │    └── Bridge glue                        │
│  ├── Frameworks/ (system frameworks)         │
│  └── Assets/                                 │
│       └── signing-materials/                 │
│            ├── dev-cert.p12 (private key)    │
│            ├── profile.mobileprovision       │
│            └── entitlements.plist            │
└──────────────────────────────────────────────┘

Runtime Documents/:
  ├── user-sources/       ← input .zig files
  ├── build-artifacts/    ← temp object files
  └── loaded-dylibs/      ← signed .dylib ready for dlopen
```

### 9.4. Execution flow

1. **Source intake.** User writes Zig code in the UI or opens a file.
2. **Compile.** Swift layer calls the C bridge `zig_compile(argc, argv)`. Output: `Documents/build-artifacts/unsigned.dylib`. A valid aarch64 Mach-O without a code signature.
3. **Sign.** Swift calls `sign_dylib(path, cert_p12_bytes, cert_p12_password, profile_bytes, entitlements_bytes)`. The function:
    - Parses the p12 (PKCS#12) via `SecPKCS12Import`, obtains a `SecIdentity` (cert + private key).
    - Computes SHA-256 of `__TEXT` and other relevant segments of the Mach-O (skipping the future LC_CODE_SIGNATURE region).
    - Builds a CodeDirectory blob (format per Apple Technotes).
    - Signs the CodeDirectory via `SecKeyCreateSignature` with `rsaSignatureMessagePKCS1v15SHA256` or ECDSA.
    - Wraps the result in CMS SignedData (ASN.1 DER).
    - Assembles a SuperBlob: magic `0xfade0cc0`, [CodeDirectory, Requirements, Entitlements, CMS].
    - Adds an LC_CODE_SIGNATURE load command to the Mach-O header.
    - Grows `__LINKEDIT` and appends the blob.
    - Recomputes `__LINKEDIT` vmsize/filesize.
    - Writes to `Documents/loaded-dylibs/signed.dylib`.
4. **Load.** Swift calls the C bridge:
    ```c
    void *h = dlopen(signed_path, RTLD_NOW | RTLD_LOCAL);
    if (!h) { log(dlerror()); return; }
    void (*entry)(void) = dlsym(h, "entry");
    entry();
    ```
5. **Execute.** Inside the dylib — full access to UIKit, Foundation, pthread, BSD sockets, the app sandbox file system, OpenGL ES / Metal, CoreBluetooth, CoreLocation, etc.

### 9.5. Entitlements

`entitlements.plist` for the main app:

```xml
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN"
 "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
    <key>application-identifier</key>
    <string>TEAMID.com.yourname.dynzig</string>
    <key>com.apple.developer.team-identifier</key>
    <string>TEAMID</string>
    <key>get-task-allow</key>
    <true/>
    <!-- NOT required: com.apple.security.cs.allow-jit (we don't JIT) -->
    <!-- NOT required: com.apple.security.cs.allow-unsigned-executable-memory -->
</dict>
</plist>
```

Entitlements for the dylib — same values; the `application-identifier` must match the same team ID.

### 9.6. Signing library — implementation options

**Option 9.6.A: Embed ldid.**

Repository: `github.com/ProcursusTeam/ldid`. Written in C++, uses OpenSSL for crypto. Pros: battle-tested across many iOS versions, supports all the needed formats. Cons: C++ deps, OpenSSL, careful porting needed to iOS.

Step by step:
1. Clone `ProcursusTeam/ldid`.
2. Build as a static library for `aarch64-ios`. You'll need to replace OpenSSL with BoringSSL or with CommonCrypto + Security.framework (iOS-native).
3. Expose a function like:
   ```cpp
   extern "C" int ldid_sign(const char *path,
                             const uint8_t *cert_der, size_t cert_len,
                             const uint8_t *key_der, size_t key_len,
                             const char *entitlements_xml,
                             const char *team_id);
   ```
4. Link into the main app.

**Option 9.6.B: Write your own signer.**

Pros: no C++ deps, full control. Cons: you need to grok the Mach-O code signature format, which is nontrivial.

References for implementation:
- Apple TN3125 "Inside Code Signing: Hashes, Signatures, and Certificates".
- Apple TN3126 "Inside Code Signing: Provisioning Profiles".
- Apple TN3127 "Inside Code Signing: Requirements".
- `github.com/apple-oss-distributions/Security` (open-source Security.framework).
- `github.com/dtolnay/rcodesign` — wait, the Rust one is by Gregory Szorc: `github.com/indygreg/apple-platform-rs/tree/main/apple-codesign`. Very readable, every constant and algorithm is documented.

Steps (if writing your own):
1. Read the Mach-O header, find the `LC_SEGMENT_64` for `__LINKEDIT`.
2. Reserve 16 KB at the end of the file for the signature (round size up to a page boundary).
3. Compute SHA-256 of each 4096-byte page from file start up to the reservation — these are **page hashes** for the CodeDirectory.
4. Compute SHA-256 of Info.plist, Requirements blob, Entitlements blob — **special slots**.
5. Build the CodeDirectory per spec (see TN3125, struct `CS_CodeDirectory`).
6. Sign the CodeDirectory: `SecKeyCreateSignature(privateKey, .rsaSignatureMessagePKCS1v15SHA256, cd_data)`.
7. Wrap the signature in CMS SignedData via `CMSEncoderCreate` / `CMSEncoderUpdateContent` / `CMSEncoderCopyEncodedContent` (present in CoreFoundation on iOS, but the API is considered deprecated — alternative: hand-roll ASN.1 DER via Security.framework).
8. Assemble the SuperBlob with magic `0xfade0cc0`.
9. Add an `LC_CODE_SIGNATURE` load command to the Mach-O (pointing at offset + size).
10. Update `__LINKEDIT` `filesize` / `vmsize`.
11. Write the updated file.

**Recommendation:** start with option 9.6.A (ldid), because a custom signer is 2–4 weeks of work with on-device debugging.

### 9.7. UIKit integration from the generated dylib

User Zig code can call UIKit directly via the Objective-C runtime. Example user code:

```zig
const objc = @cImport({
    @cInclude("objc/runtime.h");
    @cInclude("objc/message.h");
});

export fn entry() callconv(.C) void {
    const NSObject = objc.objc_getClass("NSObject");
    const UIAlertController = objc.objc_getClass("UIAlertController");
    // ... msgSend-based API calls
}
```

This works but is verbose. More practical — the host app registers **C bridge functions** that make "convenient" calls:

```swift
@_cdecl("host_show_alert")
public func hostShowAlert(title: UnsafePointer<CChar>, message: UnsafePointer<CChar>) {
    let t = String(cString: title)
    let m = String(cString: message)
    DispatchQueue.main.async {
        let alert = UIAlertController(title: t, message: m, preferredStyle: .alert)
        alert.addAction(UIAlertAction(title: "OK", style: .default))
        UIApplication.shared.windows.first?.rootViewController?.present(alert, animated: true)
    }
}
```

Then user code writes:

```zig
extern fn host_show_alert(title: [*:0]const u8, message: [*:0]const u8) void;
export fn entry() callconv(.C) void {
    host_show_alert("Hello", "From Zig!");
}
```

This approach is dramatically more convenient than raw Objective-C runtime. **You still get native execution**; only the UI calls route through a small bridge — not through a WASM interpreter.

### 9.8. Known pitfalls

**P1. Provisioning profile expiry.** A developer profile lives 1 year (paid) or 7 days (free). On expiry, all your signed dylibs stop loading. Mitigation: before signing, check the cert validity; if close to expiry, renew via Apple API or via Xcode.

**P2. Certificate revocation.** If Apple revokes your cert (e.g. for TOS violation) — all dylibs stop loading. iOS periodically checks Apple's OCSP server. Offline devices can keep working for a while, then fail.

**P3. Library validation.** By default `amfid` requires loaded dylibs to be signed with **the same team ID** as the main app, OR be a platform binary (Apple-signed). If you sign with your own cert → same team ID automatically → passes. If you want to load dylibs from a different team — you need `com.apple.security.cs.disable-library-validation` (macOS-originated entitlement, but also effective in iOS dev builds).

**P4. Path validity.** iOS is stricter about paths. `dlopen` from `Documents/`, `Library/Caches/`, `tmp/` inside the app sandbox — OK. Paths outside the sandbox — unavailable.

**P5. Timestamp.** A signature without an RFC 3161 timestamp (Apple TSA) is considered ad-hoc. For dev builds, ad-hoc is usually accepted. If you want a strict timestamp, you need network access to `timestamp.apple.com`. For a first prototype, ad-hoc is sufficient.

**P6. Zig self-hosted compiler + LLVM backend.** LLVM is C++ code, ~100 MB in debug. On iOS that's huge. Solution: use `-fno-llvm` for the self-hosted backend. Optimization quality is lower, but acceptable for scripting. Binary size shrinks 4–5×.

**P7. Compile time.** The Zig compiler runs slower on ARM mobile CPUs than on desktop. A simple program: 1–3 seconds. A complex one: 10–20 seconds. Noticeable for UX. Solution: cache compile artifacts, do incremental compilation (Zig supports it).

**P8. Memory pressure.** iOS may kill an app using >1–2 GB. Zig compiler + LLVM backend is memory-heavy. With self-hosted backend, less so. Monitor via `os_proc_available_memory()`.

**P9. File system case sensitivity.** iOS Documents — case-insensitive. Usually not a Zig compiler issue, but imports with mismatched case that work on macOS may fail on iOS.

**P10. App Transport Security.** If user code makes HTTP requests over plain `http://` (not HTTPS), they'll be blocked. Solution: `NSAppTransportSecurity` in Info.plist with `NSAllowsArbitraryLoads=true`.

### 9.9. iOS implementation roadmap (milestones)

**M1. Minimum viable.** (1–2 weeks, on a macOS dev machine)
- Build Zig for `aarch64-ios` (confirm the target works standalone).
- Link the Zig compiler as a static lib into a test iOS app.
- Pre-build a trivial dylib in Xcode, bundle it as a resource.
- `dlopen` that dylib from the app and call a function — confirm the basic mechanics work.

**M2. Signing works.** (2–3 weeks)
- Embed ldid (or write a signer).
- Export the dev cert in PKCS#12 (via Keychain Access).
- Put the cert as a bundle asset.
- At runtime: take a ready unsigned dylib, sign it, confirm `dlopen` accepts it.
- If it doesn't — open Console.app, read `amfid` logs, debug.

**M3. On-device compilation works.** (2–4 weeks)
- Hook up the Zig compiler as a library.
- Smoke test: compile a hardcoded source `export fn entry() void { }` into a dylib.
- Confirm Zig on ARM iOS emits a correct Mach-O.
- Combine with M2: compile → sign → load.

**M4. Full pipeline.** (1–2 weeks)
- UI for source input.
- Host bridge with UIKit functions.
- User-code examples: "Hello, World with an alert", "draw on a canvas", "HTTP request".

**M5. Optimization.** (ongoing)
- Incremental Zig compilation (cache by source hash).
- Binary size reduction (self-hosted backend, LTO for host).
- Signing time optimization (most of it is SHA-256; parallelize across pages).

---

## 10. Shared bridge API — recommended interface

A common C ABI that the host exposes to user code. This makes user code cross-platform.

```c
// host_api.h — header user code can @cImport

// --- Logging ---
void host_log(int level, const char *msg);

// --- Threading ---
typedef void (*thread_fn)(void *user_data);
int host_spawn_thread(thread_fn fn, void *user_data);

// --- Networking ---
typedef struct {
    int status;
    const char *body;
    size_t body_len;
} host_http_response;

host_http_response host_http_get(const char *url);
void host_http_free(host_http_response *resp);

// --- UI (platform-specific semantics, same ABI) ---
void host_ui_alert(const char *title, const char *message);
int  host_ui_prompt(const char *title, char *out_buf, size_t buf_size);
void host_ui_draw_rect(int x, int y, int w, int h, uint32_t rgba);
void host_ui_present(void);

// --- File I/O (sandboxed) ---
int host_file_read(const char *rel_path, void *buf, size_t max_len);
int host_file_write(const char *rel_path, const void *buf, size_t len);
```

User-Zig imports this via `@cImport` and writes portably. The host implements these functions differently on iOS (UIKit), Android (Activity via JNI), desktop (window / console).

---

## 11. Critical documentation (all in one place)

### Zig
- Main: `ziglang.org`
- Master docs: `ziglang.org/documentation/master/`
- Build system: `ziglang.org/learn/build-system/`
- Source: `github.com/ziglang/zig`
- Self-hosted transition: `ziglang.org/news/goodbye-cpp/`
- Compilation.zig: `github.com/ziglang/zig/blob/master/src/Compilation.zig`
- Mach-O linker: `github.com/ziglang/zig/tree/master/src/link/MachO.zig`

### Apple Code Signing
- TN2250 "iOS Code Signing Troubleshooting": `developer.apple.com/library/archive/technotes/tn2250/_index.html`
- TN3125 "Inside Code Signing: Hashes": `developer.apple.com/documentation/technotes/tn3125-inside-code-signing-hashes`
- TN3126 "Inside Code Signing: Provisioning Profiles": `developer.apple.com/documentation/technotes/tn3126-inside-code-signing-provisioning-profiles`
- TN3127 "Inside Code Signing: Requirements": `developer.apple.com/documentation/technotes/tn3127-inside-code-signing-requirements`
- WWDC23 Session 10061 "Verify app dependencies with digital signatures": `developer.apple.com/videos/play/wwdc2023/10061/`
- objc.io "Inside Code Signing": `www.objc.io/issues/17-security/inside-code-signing/`

### Signing Implementations
- ldid (ProcursusTeam fork): `github.com/ProcursusTeam/ldid`
- zsign (OpenSSL-based): `github.com/zhlynn/zsign`
- rcodesign (Rust, excellent reference): `github.com/indygreg/apple-platform-rs/tree/main/apple-codesign`
- Apple Security framework source: `github.com/apple-oss-distributions/Security`

### POSIX / Platform
- dlopen man page: `man7.org/linux/man-pages/man3/dlopen.3.html`
- Mach-O reference (legacy, still useful): `github.com/aidansteele/osx-abi-macho-file-format-reference`
- Android dynamic linker changes: `android.googlesource.com/platform/bionic/+/master/android-changes-for-ndk-developers.md`

### iOS Sideloading / Distribution
- AltStore: `altstore.io`
- SideStore: `sidestore.io`
- Enabling JIT (to understand WHY we don't use it): `docs.sidestore.io/docs/advanced/jit`

### Community Deep Dives
- Saurik "Bypassing iPhone Code Signatures": `saurik.com/codesign.html`
- Saagar Jha "Jailed Just-in-Time Compilation on iOS": `saagarjha.com/blog/2020/02/23/jailed-just-in-time-compilation-on-ios/`
- iPhone wiki "Bypassing iPhone Code Signatures": `theiphonewiki.com/wiki/Bypassing_iPhone_Code_Signatures`

---

## 12. Risks and mitigations

| Risk | Likelihood | Impact | Mitigation |
|---|---|---|---|
| Apple changes `amfid` logic in a new iOS | Medium | High | Pin the dev device iOS version; test on betas |
| Cert revocation | Low | Fatal | Have a backup Apple ID; don't mix the account with commercial activity |
| Private key leak | Low (own devices) | High | Encrypt p12 with a password, store in Keychain, never commit to git |
| Zig API breaking changes | High | Medium | Pin a specific version (e.g. 0.14.1); upgrade manually with migration |
| Binary size >100 MB | Medium | Low | Self-hosted backend (`-fno-llvm`), strip symbols |
| Compile time >10 s | Medium | Medium | Incremental compilation, hash-based caching |
| ldid won't build for iOS | Low | High | Fallback: write a signer in Swift + Security.framework (use rcodesign as reference) |

---

## 13. Final consolidated checklist

For starting work in a new chat, once everything is ready:

- [ ] macOS machine with Xcode 15+ installed.
- [ ] Apple Developer account active, target iPhone UDID registered.
- [ ] Zig 0.14.1 (or 0.15.x) cloned locally: `git clone https://github.com/ziglang/zig ~/src/zig`.
- [ ] iPhone in Developer Mode.
- [ ] Project repository created with this layout:
  ```
  dynzig/
  ├── build.zig
  ├── src/
  │   ├── host/
  │   │   ├── main.zig           (Zig part of main app; Swift optional)
  │   │   ├── bridge.zig         (C ABI for user code)
  │   │   └── signing.zig        (ldid wrapper)
  │   ├── zig_compiler/          (submodule or vendored copy of Zig compiler source)
  │   └── ldid/                  (vendored fork with iOS-compatible crypto)
  ├── ios/
  │   ├── Info.plist
  │   ├── entitlements.plist
  │   ├── DynZigHost.xcodeproj   (only for building the .ipa)
  │   └── Assets/
  │       └── signing-materials/ (not in git!)
  ├── android/
  │   └── app/                   (Gradle/Kotlin project)
  └── docs/
      └── this-plan.md           (this document)
  ```
- [ ] First milestone (M1 from §9.9) done: dlopen works with a prebuilt dylib.

---

## 14. Appendix A: Minimal user-Zig example

This example shows how user code talks to the host. The same file compiles unchanged for all targets.

```zig
// user-example.zig
// This is what the end user writes and feeds into the runtime.

const std = @import("std");

// Host API imports (declared extern; host registers these as exports)
extern fn host_log(level: c_int, msg: [*:0]const u8) void;
extern fn host_ui_alert(title: [*:0]const u8, message: [*:0]const u8) void;
extern fn host_http_get(url: [*:0]const u8) HttpResponse;

const HttpResponse = extern struct {
    status: c_int,
    body: [*]const u8,
    body_len: usize,
};

// Entry point — host calls this after dlopen/dlsym.
export fn entry() callconv(.C) void {
    host_log(0, "Zig code running in host process!");
    host_ui_alert("Hello", "From dynamically compiled Zig!");

    const resp = host_http_get("https://httpbin.org/get");
    if (resp.status == 200) {
        host_log(0, "HTTP OK");
    }
}
```

The host exports `host_log`, `host_ui_alert`, `host_http_get` — differently on each platform, but with the same C ABI.

---

## 15. Appendix B: Pseudocode for on-device iOS dylib signing

```
function sign_dylib_on_ios(dylib_path, p12_data, p12_password, entitlements_xml):
    # 1. Parse identity
    identity = SecPKCS12Import(p12_data, p12_password)
    private_key = SecIdentityCopyPrivateKey(identity)
    cert = SecIdentityCopyCertificate(identity)

    # 2. Read existing Mach-O
    macho = read_file(dylib_path)
    header = parse_macho_header(macho)
    assert header.magic == MH_MAGIC_64
    linkedit = find_segment(header, "__LINKEDIT")

    # 3. Reserve space for signature (align to 16 bytes)
    sig_offset = align_up(macho.size, 16)
    sig_space = 0x4000  # 16KB, conservative
    new_size = sig_offset + sig_space

    # 4. Compute page hashes (4KB pages) up to sig_offset
    hashes = []
    for page in chunks(macho[0:sig_offset], 4096):
        hashes.append(SHA256(page))

    # 5. Compute special slots
    # -5: Entitlements, -1: Info.plist (for bundles; dylibs usually have none)
    special_slots = {
        -5: SHA256(entitlements_xml),
        -2: SHA256(requirements_blob()),
    }

    # 6. Build CodeDirectory
    cd = CodeDirectory(
        magic = 0xfade0c02,
        version = 0x20400,
        flags = 0,
        hashOffset = ..., # computed
        identOffset = offset_of_identifier,
        nSpecialSlots = 5,
        nCodeSlots = len(hashes),
        codeLimit = sig_offset,
        hashSize = 32,       # SHA-256
        hashType = CS_HASHTYPE_SHA256,
        platform = 0,
        pageSize = 12,       # 2^12 = 4096
        identifier = team_id + "." + bundle_id,
        specialSlots = special_slots,
        codeSlots = hashes,
        teamId = team_id,
    )
    cd_bytes = serialize(cd)

    # 7. Sign CodeDirectory
    cms_signature = SecKeyCreateSignature(
        private_key,
        algorithm = .rsaSignatureMessagePKCS1v15SHA256,
        data = cd_bytes
    )
    cms_blob = wrap_in_cms_signeddata(cms_signature, cert)

    # 8. Build SuperBlob
    superblob = SuperBlob(
        magic = 0xfade0cc0,
        blobs = [
            (CSSLOT_CODEDIRECTORY,   cd_bytes),
            (CSSLOT_REQUIREMENTS,    requirements_blob()),
            (CSSLOT_ENTITLEMENTS,    entitlements_xml.encode()),
            (CSSLOT_CMS_SIGNATURE,   cms_blob),
        ]
    )
    superblob_bytes = serialize(superblob)
    assert len(superblob_bytes) <= sig_space

    # 9. Patch Mach-O
    #  9a. Extend __LINKEDIT: filesize += sig_space, vmsize += sig_space (rounded)
    modify_segment(macho, "__LINKEDIT",
                   filesize = linkedit.filesize + sig_space,
                   vmsize = round_up(linkedit.vmsize + sig_space, 0x4000))

    #  9b. Add LC_CODE_SIGNATURE load command
    add_load_command(macho, LC_CODE_SIGNATURE,
                      dataoff = sig_offset,
                      datasize = sig_space)

    #  9c. Write superblob at sig_offset
    macho[sig_offset : sig_offset + len(superblob_bytes)] = superblob_bytes

    # 10. Write back
    write_file(dylib_path, macho)
```

This is pseudocode, but the implementation structure is exactly this. Everything below `SecKeyCreateSignature` is ASN.1 / CMS plumbing. With ldid, that's taken care of for you.

---

## 16. Appendix C: Glossary

- **amfid** — Apple Mobile File Integrity Daemon, the iOS system process that verifies executable signatures.
- **dyld** — the macOS/iOS dynamic linker; loads dylibs and resolves symbols.
- **Mach-O** — Darwin (macOS/iOS) executable file format.
- **CodeDirectory (CD)** — core signature structure; contains hashes of every page in the binary.
- **SuperBlob** — container for all signature parts (CD + CMS + Entitlements + Requirements).
- **CMS** — Cryptographic Message Syntax (RFC 5652); the ASN.1 format for digital signatures.
- **Team ID** — 10-character Apple Developer team identifier, used for library validation.
- **Provisioning Profile** — Apple-signed XML binding team ID + app identifier + UDIDs + entitlements.
- **Developer Mode** — iOS 16+ setting; required to run dev-signed apps.
- **JIT** — Just-In-Time compilation (**we do not use it**).
- **library validation** — amfid policy requiring the same team ID on the main app and all loaded dylibs.
- **hardened runtime** — macOS policy requiring entitlements for certain operations.

---

End of document. For the next iteration in a new chat, starting at milestone M1 (§9.9) is recommended.
