# Dynamic Zig Compilation & Execution — Cross-Platform Technical Plan

> 🇬🇧 English version: **[zig-runtime-compilation-plan.md](zig-runtime-compilation-plan.md)**

**Статус документа:** технический план с детальной проработкой для реализации.
**Дата:** апрель 2026.
**Целевые Zig-версии:** 0.14.x / 0.15.x (по состоянию на момент написания).
**Характер проекта:** исследовательский, личный. Не предназначен для массовой дистрибуции. App Store не требуется. Jailbreak не используется. Авторы допускают встраивание приватного ключа разработчика в свой собственный билд на свои устройства.

---

## 0. Как читать этот документ

Документ писался как **контекст для следующих чатов**. В нём собраны:

1. Постановка задачи и история принятых решений (чтобы не переигрывать их заново).
2. Архитектура решения по каждой ОС отдельно.
3. Глубокая проработка iOS (самая нетривиальная платформа).
4. Ссылки на ключевую документацию.
5. Список известных подводных камней.

Когда вы открываете этот файл в новом чате, сообщайте ассистенту: «Прочитай этот документ полностью, это план проекта». После этого можно сразу переходить к конкретному шагу реализации.

---

## 1. Постановка задачи

Создать приложение, которое:

- **Принимает Zig-исходный код в рантайме** (от пользователя, из файла, из сети, из DSL-редактора внутри приложения — неважно).
- **Компилирует его** в нативный исполняемый формат целевой платформы.
- **Исполняет результат** с полным доступом к платформенным API (UIKit/UIApplication на iOS, Activity/JNI на Android, Win32/Cocoa/X11 на десктопе), потокам, сети, файловой системе, аппаратному ускорению.
- **Работает на шести таргетах:** Windows x86_64, Linux x86_64, macOS arm64 + x86_64, Android arm64 (+ armv7 по желанию), iOS arm64.

Не нужно: поддержка всех возможных устройств, поддержка магазинов приложений, ограничение на «безопасный» subset Zig. Это личный исследовательский проект на контролируемых устройствах.

---

## 2. История принятых решений

Эта секция объясняет, **почему** архитектура именно такая. В другом чате это сократит время на повторное обсуждение.

### 2.1. Рассмотренные подходы

| Подход | Решение | Причина |
|---|---|---|
| Подпроцесс `zig build-exe` + запуск бинарника | Использовать на Win/Lin/Mac/Android, **отклонить для iOS** | iOS sandbox блокирует `execve` произвольных бинарей |
| WASM + интерпретатор (wasm3 / JavaScriptCore) | **Отклонить как основной путь** | Нет прямого доступа к UIKit/OS API, требует ручных bridge-функций на каждый вызов |
| JIT в процесс (MAP_JIT + Zig→память→выполнить) | **Отклонить** | На iOS требует JIT-entitlement + debugger attach (JitStreamer), плохой UX, хрупко |
| TrollStore bypass | **Отклонить** | Только для устаревших iOS (<17), гарантии нет |
| Server-side компиляция + dlopen подписанного dylib | **Отклонить** | Зависимость от сети, секьюрное хранение ключа, задержки |
| **On-device компиляция + on-device подпись + dlopen** | **ВЫБРАННЫЙ ПУТЬ ДЛЯ iOS** | Всё происходит локально, производительность нативная, UIKit доступен напрямую |

### 2.2. Почему on-device подпись работает

Это критичный пункт. Объяснение кратко:

- `amfid` (AppleMobileFileIntegrity daemon) проверяет подпись при `dlopen`, но ему **безразлично, где эта подпись была создана**. Он проверяет математику хэшей + цепочку сертификата до Apple root + совпадение team ID. Всё это можно сделать на самом устройстве, если у вас есть приватный ключ.
- Подписание — это детерминированный криптографический алгоритм. Байты подписи, созданные на iPhone, неотличимы от байтов, созданных на Mac-е через `codesign`.
- Swift Playgrounds (единственное Apple-приложение, делающее on-device compile+sign+run) использует приватный entitlement, но, по-видимому, для доступа к приватным компиляторным SPI, а не для `dlopen` как такового. Для нашего сценария приватный entitlement не требуется — мы несём свой Zig-компилятор.

### 2.3. Что принимаем как риск

- **Private key в билде**: технически нарушение Apple Developer Program License Agreement. Оправдано для локального исследования на собственных устройствах автора.
- **7-дневная пересиндка** при free Apple ID или **1-годичная** при paid Developer Program. После истечения сертификата `amfid` отклоняет подписанные им dylibs.
- **Ограниченный круг устройств** (UDID должны быть в provisioning profile).

---

## 3. Общая архитектура

Приложение во всех таргетах имеет одну и ту же логическую структуру:

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
│  - Парсинг + семантика + codegen            │
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
│  имеет полный доступ к OS API, памяти, etc. │
└─────────────────────────────────────────────┘
```

Ключевой принцип: **компилятор и лоадер — это библиотеки**, слинкованные в ваше приложение. Подпроцессов нигде, кроме как на desktop/Android, не запускается.

---

## 4. Встраивание Zig-компилятора как библиотеки

Эта часть едина для всех платформ.

### 4.1. Текущее состояние Zig

На Zig 0.14+ компилятор полностью self-hosted (написан на Zig, C++ backend удалён). Исходники: `github.com/ziglang/zig`, ключевые модули:

- `src/main.zig` — CLI entry point.
- `src/Compilation.zig` — основной оркестратор компиляции.
- `src/Module.zig` — модель модулей и типов.
- `src/Sema.zig` — семантический анализ.
- `src/codegen/` — бекенды (llvm, x86_64, aarch64, wasm, c).
- `src/link/` — линкеры (Elf, MachO, Coff, Wasm).

Публичного стабильного библиотечного API у Zig **нет**. Между минорными версиями структуры могут меняться.

### 4.2. Стратегия встраивания

Два варианта:

**Вариант А: CLI-as-library.** Собрать `zig` как статическую библиотеку с точкой входа `zig_main(argc, argv)` и вызывать с массивом аргументов вида `["zig", "build-lib", "-dynamic", "-target", "aarch64-ios", "-O", "ReleaseFast", "input.zig", "-femit-bin=output.dylib"]`. Внутри это запустит ту же логику, что и консольный `zig`.

Нюансы:
- Нужно пропатчить `src/main.zig`, чтобы `std.process.exit` не вызывался — иначе он прибьёт всё приложение.
- Перехват stdout/stderr через `dup2` на свои файловые дескрипторы для логов.
- Доступ к файловой системе идёт через обычные syscall-ы — на iOS это app sandbox, нужно использовать пути внутри `Documents/` или `tmp/`.
- Нужно pinнуть конкретную версию Zig и не обновлять, пока не проверены все изменения.

**Вариант Б: Direct API.** Импортировать `Compilation.zig` напрямую, создавать `Compilation`-объект, конфигурировать и звать `.update()`. Более чистый, меньше накладных расходов, но **максимально завязан на внутреннюю версию компилятора** — при смене версии Zig ломается всё.

**Рекомендация:** начать с варианта А. Перейти на Б, только если будут специфические нужды (например, перехватить интерместеры compile-time вычислений).

### 4.3. Сборка

В `build.zig` главного приложения:

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

Размер получающегося бинаря: приблизительно 40-90 MB в зависимости от таргета и backend-а (LLVM добавляет больше всего). Для iOS можно отключить LLVM backend и использовать self-hosted (`-fno-llvm`), это уменьшит размер до 15-25 MB, но потеряет часть оптимизаций.

### 4.4. Вызов из host-приложения

С C ABI:

```c
extern int zig_compile(int argc, const char **argv);
```

Из Swift (iOS/macOS):

```swift
let args = ["zig", "build-lib", "-dynamic", "-target", "aarch64-ios",
            inputPath, "-femit-bin=" + outputPath]
let cArgs = args.map { strdup($0) }
let result = zig_compile(Int32(args.count), cArgs.map { UnsafePointer($0) })
cArgs.forEach { free($0) }
```

Из Kotlin (Android) — через JNI, после `System.loadLibrary("dynzig")`.

---

## 5. Windows — детальный план

### 5.1. Таргеты
- `x86_64-windows-msvc` (основной).
- По желанию: `aarch64-windows` для Surface Pro X.

### 5.2. Поток исполнения

1. Приложение написано на Zig (GUI опционально: WinAPI / GDI+, либо просто консоль).
2. Пользователь даёт Zig-исходник (в файл или в TextBox).
3. Host вызывает `zig_compile` с параметрами сборки `-target x86_64-windows -dynamic -fPIC`.
4. На выходе — `generated.dll` в `%APPDATA%\DynZig\` или временной папке.
5. Host вызывает `LoadLibraryW(L"generated.dll")` → `GetProcAddress(hmod, "entry")` → вызов.

### 5.3. Тонкости Windows

- **DLL export:** пользовательский код должен экспортировать символ. В Zig: `export fn entry() callconv(.C) void { ... }`.
- **Search path:** перед `LoadLibrary` вызвать `SetDllDirectoryW` или использовать absolute path, чтобы не тянуть зависимости из неизвестных мест.
- **Antivirus:** Windows Defender может проверять новосозданные DLL на эвристике. На dev-машине обычно не мешает, но пользователям может добавить задержку. Лечится signing-ом Code Signing сертификатом (EV preferred).
- **Unload:** `FreeLibrary(hmod)`. Обратите внимание, что если DLL оставляет поток запущенным — процесс зависнет.

### 5.4. Альтернатива: `.exe` как отдельный процесс

Если не нужна тесная интеграция с host-процессом:

```zig
var child = std.process.Child.init(&.{exe_path}, allocator);
try child.spawn();
const term = try child.wait();
```

Проще в отладке (crash в user-коде не валит host), но нет shared state.

### 5.5. Документация
- MSDN: `LoadLibrary`, `GetProcAddress`, `FreeLibrary`.
- Zig MSVC cross-compilation: `ziglang.org/learn/overview/` → cross-compilation.

---

## 6. Linux — детальный план

### 6.1. Таргеты
- `x86_64-linux-gnu` — основной.
- `x86_64-linux-musl` — для полностью статических сборок.
- `aarch64-linux-gnu` — для ARM-серверов/Raspberry Pi.

### 6.2. Поток исполнения

Аналогичен Windows, но инструменты POSIX:

1. Компиляция → `/tmp/dynzig-XXXXXX/generated.so`.
2. `dlopen("/tmp/.../generated.so", RTLD_NOW | RTLD_LOCAL)` → `dlsym(h, "entry")`.
3. Вызов.

### 6.3. Тонкости Linux

- **`glibc` vs `musl`:** user-код и host должны использовать одну и ту же libc. Проще всего — оба собирать с одним `-target`.
- **`noexec` на `/tmp`:** некоторые дистрибутивы монтируют `/tmp` с флагом `noexec`. Решение — писать в `~/.cache/dynzig/` или использовать `memfd_create` + `fdlopen` (glibc 2.26+).
- **SELinux / AppArmor:** на жёстко настроенных системах может блокировать `dlopen` из user-writable путей. На dev-машине обычно не мешает.
- **RPATH:** если user-код зависит от других .so, нужно указать их в rpath на этапе линковки, либо заранее `dlopen` их сам host.

### 6.4. `memfd_create` трюк (опционально)

Позволяет не писать файл на диск вообще:

```zig
const fd = std.os.linux.memfd_create("dynzig", 0);
try std.posix.write(fd, compiled_bytes);
const path = try std.fmt.allocPrint(alloc, "/proc/self/fd/{d}", .{fd});
const handle = std.c.dlopen(path.ptr, RTLD_NOW);
```

Плюсы: код нигде не оседает. Минусы: glibc-специфично, на musl нужен другой подход.

### 6.5. Документация
- `man 3 dlopen`, `man 3 dlsym`, `man 2 memfd_create`.
- Linux ELF specification (для понимания формата, что выдаёт Zig).

---

## 7. macOS — детальный план

### 7.1. Таргеты
- `aarch64-macos` — Apple Silicon.
- `x86_64-macos` — Intel (для совместимости).
- Universal Binary (fat Mach-O) — опционально.

### 7.2. Поток исполнения

1. Компиляция → `~/Library/Application Support/DynZig/generated.dylib`.
2. Если приложение распространяется:
   - **Без нотаризации и с signing-ом Developer ID**: нужен entitlement `com.apple.security.cs.disable-library-validation` в hardened runtime, иначе dlopen откажет на dylibs с чужим team ID. Если сами подписываете dylib своим ID — не нужно.
   - **Для личного использования без Gatekeeper**: всё «просто работает», но на новых macOS (14+) при первом запуске пользователь может получить запрос Gatekeeper.
3. `dlopen` → `dlsym` → вызов.

### 7.3. Тонкости macOS

- **Hardened runtime:** если приложение подписано с ним (обязательно для нотаризации), вам нужны entitlements `com.apple.security.cs.allow-unsigned-executable-memory` (если используете JIT, что мы НЕ делаем) или `com.apple.security.cs.disable-library-validation` для загрузки dylibs, подписанных другим team ID.
- **Для Zig-скомпилированных dylib:** подписывайте их тем же team ID, что и основное приложение — тогда library validation проходит без дополнительных entitlements.
- **Команда подписи:** `codesign --sign "Developer ID Application: Your Name" --timestamp --options runtime generated.dylib`.
- **Для App Store macOS** — не актуально, вы сказали что магазины не нужны.
- **JIT не нужен**: мы компилируем в файл, не в память. Гораздо проще Code Signing.

### 7.4. Единственное отличие от iOS

Gatekeeper на macOS проверяет подпись **при первом запуске**, дальше кеширует. amfid как таковой на macOS есть, но он куда мягче — доверяет любому Developer ID + нотаризации. На **macOS для личного использования можно даже не подписывать** dylib-ы, если Gatekeeper отключён или SIP в permissive mode. Это делает macOS-таргет проще iOS.

### 7.5. Документация
- Apple TN3125 (Inside Code Signing: hashes): `developer.apple.com/documentation/technotes/tn3125-inside-code-signing-hashes`.
- `man dlopen` (системная, Darwin).
- `man codesign`.

---

## 8. Android — детальный план

### 8.1. Таргеты
- `aarch64-linux-android` — основной, все современные устройства.
- `x86_64-linux-android` — для эмуляторов.
- `armv7a-linux-androideabi` — только если нужна поддержка очень старых устройств.

Минимальная Android API: 26 (Oreo) или 29 (10). API 29+ предпочтительнее — более современные политики SELinux, проще обращаться с executable-файлами.

### 8.2. Поток исполнения

1. Host написан на Kotlin или Java + C++ JNI wrapper.
2. Zig-компилятор встроен как `.so` и подгружается через `System.loadLibrary("dynzig_host")` при старте приложения.
3. Пользовательский исходник: принимается в UI, сохраняется в `context.filesDir + "/src.zig"`.
4. Компиляция: JNI-мост вызывает `zig_compile(...)` в C ABI, на выходе — `context.filesDir + "/generated.so"`.
5. Загрузка: `System.load("/data/data/<pkg>/files/generated.so")` или `dlopen` через JNI.
6. Вызов: `dlsym` + function pointer через JNI.

### 8.3. Тонкости Android

- **Android 10+ restrictions:** с API 29 запрещено исполнение файлов, извлечённых из APK напрямую. Но файлы, **созданные в `getFilesDir()` самим приложением**, исполнять и загружать можно. Zig-компилятор должен писать именно туда.
- **W^X:** Android не требует JIT-entitlements, потому что мы не JIT-им — пишем файл, потом загружаем.
- **SELinux:** `u:object_r:app_data_file:s0` домен позволяет execute от app's own UID. Проблем обычно нет.
- **Linker:** Android использует свой bionic-linker, некоторые glibc-конструкции (`ifunc`, сложные TLS-модели) не поддерживаются. Zig должен компилироваться с `-target aarch64-linux-android` и соответствующим API level.
- **NDK compatibility:** если user-код хочет `#include <jni.h>` или вызывать Android SDK методы — нужны JNI bindings. Zig ими формально не обладает, но можно импортировать через `@cImport` заголовки NDK.
- **App Bundle (AAB):** если планируете публикацию в Google Play — Play Store разрешает dlopen динамически скомпилированного кода, **в отличие от Apple**. Публикация не нужна в этом проекте, но возможность сохраняется.

### 8.4. Пример Kotlin-моста

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

### 8.5. Документация
- Android NDK: `developer.android.com/ndk`.
- Android dynamic linker limitations: `android.googlesource.com/platform/bionic/+/master/android-changes-for-ndk-developers.md`.
- Zig cross-compilation to Android: `ziglang.org` (раздел targets).

---

## 9. iOS — детальный план (основная сложность проекта)

### 9.1. Предпосылки iOS

iOS отличается от других платформ тем, что:

1. Любой исполняемый Mach-O код — хоть main app, хоть dylib — проверяется ядерной подсистемой `amfid` на валидность подписи.
2. `fork()` + `execve()` произвольных бинарных файлов sandbox запрещает полностью.
3. Код должен быть подписан сертификатом, chainjoin-ящимся к Apple root CA.
4. Провижининг: устройство должно быть в списке UDID-ов provisioning profile.
5. Developer Mode (iOS 16+) должен быть включён.

Но — и это ключевое — **процесс подписи происходит на стороне, у которой есть приватный ключ**. Ядро iOS проверяет математику хэшей и доверие цепочке сертификатов. **Оно не знает и не интересуется, какой процесс создал подпись.** Значит, если процесс внутри iOS-приложения имеет доступ к приватному ключу, он может создавать подписи, которые `amfid` примет.

### 9.2. Требуемые компоненты

| Компонент | Назначение | Где берётся |
|---|---|---|
| Apple Developer Account | Для генерации сертификатов и provisioning profile | `developer.apple.com` ($99/год paid, или free Apple ID с 7-дневным лимитом) |
| iOS Development Certificate (.cer + private key .p12) | Подпись приложения и dylib-ов | Xcode → Preferences → Accounts → Manage Certificates, или Keychain Access → export |
| Provisioning Profile (.mobileprovision) | Привязка к team ID + UDID-ам устройств + entitlements | Apple Developer portal, автоматически через Xcode |
| Device UDID | Регистрация устройства в profile | Xcode → Window → Devices, или `idevice_id` |
| Developer Mode enabled | Требование iOS 16+ для запуска dev-сборок | Settings → Privacy & Security → Developer Mode |
| Zig compiler as library | On-device компиляция | Собственная сборка из `github.com/ziglang/zig`, см. секцию 4 |
| Signing library | On-device подпись dylib | `ldid` (ProcursusTeam fork) или собственная реализация |

### 9.3. Архитектура приложения

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
  └── loaded-dylibs/      ← signed .dylib готовые к dlopen
```

### 9.4. Поток исполнения

1. **Приём исходника.** Пользователь пишет Zig-код в UI или открывает файл.
2. **Компиляция.** Swift-слой вызывает C-мост `zig_compile(argc, argv)`. На выходе — `Documents/build-artifacts/unsigned.dylib`. Это валидный Mach-O aarch64 без code signature.
3. **Подпись.** Swift вызывает `sign_dylib(path, cert_p12_bytes, cert_p12_password, profile_bytes, entitlements_bytes)`. Функция делает:
    - Парсит p12 (PKCS#12) через `SecPKCS12Import`, получает `SecIdentity` (cert + private key).
    - Вычисляет SHA-256 хэши __TEXT и других релевантных сегментов Mach-O (с пропуском будущего LC_CODE_SIGNATURE).
    - Строит CodeDirectory blob (формат из Apple Technotes).
    - Подписывает CodeDirectory через `SecKeyCreateSignature` с алгоритмом `rsaSignatureMessagePKCS1v15SHA256` или ECDSA.
    - Оборачивает результат в CMS SignedData (ASN.1 DER).
    - Собирает SuperBlob: magic `0xfade0cc0`, [CodeDirectory, Requirements, Entitlements, CMS].
    - Добавляет LC_CODE_SIGNATURE load command в Mach-O header.
    - Расширяет __LINKEDIT и дописывает blob.
    - Пересчитывает __LINKEDIT vmsize/filesize.
    - Записывает в `Documents/loaded-dylibs/signed.dylib`.
4. **Загрузка.** Swift вызывает C-мост:
    ```c
    void *h = dlopen(signed_path, RTLD_NOW | RTLD_LOCAL);
    if (!h) { log(dlerror()); return; }
    void (*entry)(void) = dlsym(h, "entry");
    entry();
    ```
5. **Исполнение.** Внутри dylib — полный доступ к UIKit, Foundation, pthread, BSD sockets, файловой системе в sandbox приложения, OpenGL ES / Metal, CoreBluetooth, CoreLocation и т.д.

### 9.5. Entitlements

Файл `entitlements.plist` для main app:

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
    <!-- НЕ требуется: com.apple.security.cs.allow-jit (мы не JIT-им) -->
    <!-- НЕ требуется: com.apple.security.cs.allow-unsigned-executable-memory -->
</dict>
</plist>
```

Entitlements для dylib — те же самые + `application-identifier` должен соответствовать тому же team ID.

### 9.6. Библиотека подписи — варианты реализации

**Вариант 9.6.A: Встроить ldid.**

Репозиторий: `github.com/ProcursusTeam/ldid`. Написан на C++, использует OpenSSL для криптографии. Плюсы: протестирован на множестве iOS-версий, поддерживает все нужные форматы. Минусы: C++ зависимости, OpenSSL, требует аккуратной портирования на iOS.

Пошагово:
1. Склонировать `ProcursusTeam/ldid`.
2. Собрать как static library под `aarch64-ios`. Понадобится заменить OpenSSL на BoringSSL или на CommonCrypto+Security.framework (iOS-native).
3. Экспонировать функцию типа:
   ```cpp
   extern "C" int ldid_sign(const char *path,
                             const uint8_t *cert_der, size_t cert_len,
                             const uint8_t *key_der, size_t key_len,
                             const char *entitlements_xml,
                             const char *team_id);
   ```
4. Слинковать в main app.

**Вариант 9.6.B: Написать signer самостоятельно.**

Плюсы: нет C++ зависимостей, полный контроль. Минусы: нужно разобраться в формате Mach-O code signature, что нетривиально.

Референсы для реализации:
- Apple TN3125 «Inside Code Signing: Hashes, Signatures, and Certificates».
- Apple TN3126 «Inside Code Signing: Provisioning Profiles».
- Apple TN3127 «Inside Code Signing: Requirements».
- `github.com/apple-oss-distributions/Security` (open source source of Security.framework).
- `github.com/dtolnay/rcodesign` (Rust implementation, очень читаемый, все константы и алгоритмы задокументированы).

Шаги реализации (если пишете сами):
1. Прочитать Mach-O заголовок, найти `LC_SEGMENT_64` для `__LINKEDIT`.
2. Выделить 16KB в конце файла под подпись (округлить размер до page boundary).
3. Посчитать SHA-256 каждой страницы (4096 байт) в диапазоне от начала файла до начала резервирования под подпись. Это **page hashes** для CodeDirectory.
4. Посчитать SHA-256 от Info.plist, Requirements blob, Entitlements blob — это **special slots**.
5. Собрать CodeDirectory согласно формату (см. TN3125, struct `CS_CodeDirectory`).
6. Подписать CodeDirectory: `SecKeyCreateSignature(privateKey, .rsaSignatureMessagePKCS1v15SHA256, cd_data)`.
7. Обернуть подпись в CMS SignedData через `CMSEncoderCreate` / `CMSEncoderUpdateContent` / `CMSEncoderCopyEncodedContent` (есть в CoreFoundation на iOS, но API считается deprecated — альтернатива: вручную ASN.1 DER через Security.framework).
8. Собрать SuperBlob с magic `0xfade0cc0`.
9. Добавить `LC_CODE_SIGNATURE` load command в Mach-O (ссылка на offset + size блоба).
10. Обновить __LINKEDIT `filesize` / `vmsize`.
11. Записать обновлённый файл.

**Рекомендация:** начать с варианта 9.6.A (ldid), потому что самописный signer — это 2-4 недели работы с отладкой на реальных устройствах.

### 9.7. Интеграция с UIKit из сгенерированного dylib

Пользовательский Zig-код может напрямую вызывать UIKit через Objective-C runtime. Пример user-кода:

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

Это работоспособно, но громоздко. Практичнее — пусть host-приложение регистрирует **C-функции моста**, которые делают «удобные» вызовы:

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

Тогда user-код пишет:

```zig
extern fn host_show_alert(title: [*:0]const u8, message: [*:0]const u8) void;
export fn entry() callconv(.C) void {
    host_show_alert("Hello", "From Zig!");
}
```

Этот подход в разы удобнее чем прямой Objective-C runtime. **Вы по-прежнему получаете нативное исполнение**, просто UI-операции проходят через небольшой мост — а не через WASM-интерпретатор.

### 9.8. Известные подводные камни

**P1. Provisioning profile expiry.** Developer profile живёт 1 год (paid) или 7 дней (free). При истечении — все подписанные вами dylib перестанут загружаться. Решение: перед подписью проверять срок годности cert; если скоро истекает — запросить новый через Apple API или через Xcode.

**P2. Certificate revocation.** Если Apple отозвал ваш сертификат (например, из-за TOS violation) — все dylib отказываются загружаться. iOS периодически сверяется с Apple OCSP-сервером. Offline device может некоторое время работать, потом — нет.

**P3. library validation.** По умолчанию amfid требует, чтобы dylib был подписан **тем же team ID**, что и main app, ИЛИ был platform binary (Apple-подписан). Если сами подписываете своим cert → автоматически тот же team ID → проходит. Если хотите загружать dylib от другого team — нужен entitlement `com.apple.security.cs.disable-library-validation` (обычно macOS, но на iOS dev-сборках тоже действует).

**P4. Path validity.** iOS строже относится к путям. `dlopen` из `Documents/`, `Library/Caches/`, `tmp/` внутри sandbox приложения — OK. Пути за пределами sandbox — недоступны.

**P5. Timestamp.** Подпись без RFC 3161 timestamp (Apple TSA) считается ad-hoc. Для dev-сборок ad-hoc обычно принимается. Если нужен strict timestamp — нужна сеть до `timestamp.apple.com`. Для первого прототипа — ad-hoc достаточно.

**P6. Zig self-hosted компилятор + LLVM backend.** LLVM — это C++ код, ~100 MB в debug. На iOS это огромно. Решение: использовать `-fno-llvm` для self-hosted backend'а. Качество оптимизаций ниже, но для скриптинга достаточно. Плюс самый размер бинаря уменьшается в 4-5 раз.

**P7. Compile time.** Zig-компилятор на ARM mobile CPU работает медленнее, чем на desktop. Простая программа — 1-3 секунды. Сложная — 10-20 секунд. Это ощутимо для UX. Решение: кешировать compile artifacts, делать инкрементальную компиляцию (Zig это поддерживает).

**P8. Memory pressure.** iOS может прибить приложение при использовании >1-2 GB. Zig-компилятор + LLVM backend ест много. При self-hosted backend — меньше. Мониторить через `os_proc_available_memory()`.

**P9. File system case sensitivity.** iOS Documents — case-insensitive. Для Zig-компилятора это обычно не проблема, но бывает, что разные импорты с разным регистром в тестах работают на macOS но ломаются на iOS.

**P10. App Transport Security.** Если пользовательский код делает HTTP-запросы на `http://` (не HTTPS), они будут блокироваться. Решение: `NSAppTransportSecurity` в Info.plist с `NSAllowsArbitraryLoads=true`.

### 9.9. Пошаговая дорожная карта реализации iOS (milestones)

**M1. Minimum viable.** (1-2 недели, на macOS dev-машине)
- Собрать Zig под `aarch64-ios` (отдельно убедиться, что target работает).
- Слинковать Zig-компилятор как static lib в тестовое iOS-приложение.
- Через Xcode предварительно собрать простейший dylib, положить в app bundle как resource.
- Сделать `dlopen` этого dylib из приложения, вызвать функцию — убедиться, что основная механика работает.

**M2. Подпись работает.** (2-3 недели)
- Встроить ldid (или написать signer).
- Достать dev-cert в PKCS#12 формате (через Keychain Access).
- Положить cert как asset в bundle.
- В рантайме: взять готовый unsigned dylib, подписать им, убедиться что `dlopen` принимает.
- Если не принимает — смотреть в Console.app логи `amfid`, разбираться.

**M3. Компиляция работает on-device.** (2-4 недели)
- Подключить Zig-компилятор как библиотеку.
- Простейший тест: компилировать hardcoded source `export fn entry() void { }` в dylib.
- Убедиться что Zig на ARM iOS корректно генерирует Mach-O.
- Объединить с M2: скомпилировать → подписать → загрузить.

**M4. Полный pipeline.** (1-2 недели)
- UI для ввода исходника.
- Host bridge с функциями UIKit.
- Примеры user-кода: «Hello, World с alert», «рисование на canvas», «HTTP request».

**M5. Оптимизация.** (постоянно)
- Инкрементальная компиляция Zig (кэш по hashу исходника).
- Уменьшение размера бинаря (self-hosted backend, LTO для host).
- Оптимизация времени подписи (большинство времени — SHA-256, параллельно по страницам).

---

## 10. Shared bridge API — рекомендуемый интерфейс

Общий C ABI, который host экспортирует в user-код. Это делает user-код кроссплатформенным.

```c
// host_api.h — header, который user-код может @cImport

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

// --- UI (platform-specific semantics, but same ABI) ---
void host_ui_alert(const char *title, const char *message);
int  host_ui_prompt(const char *title, char *out_buf, size_t buf_size);
void host_ui_draw_rect(int x, int y, int w, int h, uint32_t rgba);
void host_ui_present(void);

// --- File I/O (sandboxed) ---
int host_file_read(const char *rel_path, void *buf, size_t max_len);
int host_file_write(const char *rel_path, const void *buf, size_t len);
```

User-Zig импортирует это через `@cImport` и пишет кроссплатформенно. Host реализует эти функции по-разному на iOS (UIKit), Android (Activity via JNI), desktop (окно/console).

---

## 11. Критическая документация (собрано в одном месте)

### Zig
- Главная: `ziglang.org`
- Документация master: `ziglang.org/documentation/master/`
- Build system: `ziglang.org/learn/build-system/`
- Source: `github.com/ziglang/zig`
- Self-hosted transition: `ziglang.org/news/goodbye-cpp/`
- Compilation.zig: `github.com/ziglang/zig/blob/master/src/Compilation.zig`
- Mach-O linker: `github.com/ziglang/zig/tree/master/src/link/MachO.zig`

### Apple Code Signing
- TN2250 «iOS Code Signing Troubleshooting»: `developer.apple.com/library/archive/technotes/tn2250/_index.html`
- TN3125 «Inside Code Signing: Hashes»: `developer.apple.com/documentation/technotes/tn3125-inside-code-signing-hashes`
- TN3126 «Inside Code Signing: Provisioning Profiles»: `developer.apple.com/documentation/technotes/tn3126-inside-code-signing-provisioning-profiles`
- TN3127 «Inside Code Signing: Requirements»: `developer.apple.com/documentation/technotes/tn3127-inside-code-signing-requirements`
- WWDC23 Session 10061 «Verify app dependencies with digital signatures»: `developer.apple.com/videos/play/wwdc2023/10061/`
- objc.io «Inside Code Signing»: `www.objc.io/issues/17-security/inside-code-signing/`

### Signing Implementations
- ldid (ProcursusTeam fork): `github.com/ProcursusTeam/ldid`
- zsign (OpenSSL-based): `github.com/zhlynn/zsign`
- rcodesign (Rust, отличный референс): `github.com/indygreg/apple-platform-rs/tree/main/apple-codesign`
- Apple Security framework source: `github.com/apple-oss-distributions/Security`

### POSIX / Platform
- dlopen man page: `man7.org/linux/man-pages/man3/dlopen.3.html`
- Mach-O reference (legacy, но всё ещё полезен): `github.com/aidansteele/osx-abi-macho-file-format-reference`
- Android dynamic linker changes: `android.googlesource.com/platform/bionic/+/master/android-changes-for-ndk-developers.md`

### iOS Sideloading / Distribution
- AltStore: `altstore.io`
- SideStore: `sidestore.io`
- Enabling JIT (для понимания, ПОЧЕМУ мы его не используем): `docs.sidestore.io/docs/advanced/jit`

### Community Deep Dives
- Saurik «Bypassing iPhone Code Signatures»: `saurik.com/codesign.html`
- Saagar Jha «Jailed Just-in-Time Compilation on iOS»: `saagarjha.com/blog/2020/02/23/jailed-just-in-time-compilation-on-ios/`
- iPhone wiki «Bypassing iPhone Code Signatures»: `theiphonewiki.com/wiki/Bypassing_iPhone_Code_Signatures`

---

## 12. Риски и смягчения

| Риск | Вероятность | Влияние | Смягчение |
|---|---|---|---|
| Apple меняет amfid логику в новой iOS | Средняя | Высокое | Pin-ить iOS-версию dev-устройства; тестировать на beta iOS |
| Revocation сертификата | Низкая | Фатальное | Иметь резервный Apple ID; не вовлекать аккаунт в коммерческую деятельность |
| Утечка private key | Низкая (устройство ваше) | Высокое | Шифрование p12 паролем, хранение в Keychain, не коммитить в git |
| Zig API breaking changes | Высокая | Среднее | Pin конкретную версию (0.14.1 например); обновлять вручную с миграцией |
| Размер бинаря >100 MB | Средняя | Низкое | Self-hosted backend (`-fno-llvm`), strip символов |
| Compile time >10 сек | Средняя | Среднее | Incremental compilation, caching по hash исходника |
| ldid не собирается под iOS | Низкая | Высокое | Резервный план: написать signer на Swift+Security.framework (см. rcodesign как референс) |

---

## 13. Итоговый сводный чеклист

Для старта работы в другом чате, когда всё готово:

- [ ] macOS-машина с Xcode 15+ установлена.
- [ ] Apple Developer account активен, UDID целевого iPhone добавлен.
- [ ] Zig 0.14.1 (или 0.15.x) склонирован локально: `git clone https://github.com/ziglang/zig ~/src/zig`.
- [ ] Устройство iPhone в Developer Mode.
- [ ] Репозиторий проекта создан со следующей структурой:
  ```
  dynzig/
  ├── build.zig
  ├── src/
  │   ├── host/
  │   │   ├── main.zig           (Zig часть main app; опционально Swift)
  │   │   ├── bridge.zig         (C ABI для user-кода)
  │   │   └── signing.zig        (обёртка над ldid)
  │   ├── zig_compiler/          (submodule или vendored copy Zig compiler source)
  │   └── ldid/                  (vendored fork with iOS-compatible crypto)
  ├── ios/
  │   ├── Info.plist
  │   ├── entitlements.plist
  │   ├── DynZigHost.xcodeproj   (только для сборки .ipa)
  │   └── Assets/
  │       └── signing-materials/ (не в git!)
  ├── android/
  │   └── app/                   (Gradle/Kotlin project)
  └── docs/
      └── this-plan.md           (этот документ)
  ```
- [ ] Первая milestone (M1 из секции 9.9) закрыта: dlopen работает с заранее собранным dylib.

---

## 14. Приложение A: Минимальный пример user-Zig кода

Этот пример показывает, как user-код взаимодействует с host-слоем. Тот же файл компилируется без изменений под все таргеты.

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

Host экспортирует `host_log`, `host_ui_alert`, `host_http_get` — на каждой платформе по-своему, но с одинаковым C ABI.

---

## 15. Приложение B: Псевдокод процесса подписи dylib на iOS

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
    sig_space = 0x4000  # 16KB, conservatively
    new_size = sig_offset + sig_space

    # 4. Compute page hashes (4KB pages) up to sig_offset
    hashes = []
    for page in chunks(macho[0:sig_offset], 4096):
        hashes.append(SHA256(page))

    # 5. Compute special slots
    # -5: Entitlements, -1: Info.plist (for bundles, but dylib has none usually)
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

Это псевдокод, но структура реализации ровно такая. Всё, что ниже уровня `SecKeyCreateSignature` — ASN.1 возня с CMS. Если используете ldid, он это берёт на себя.

---

## 16. Приложение C: Глоссарий

- **amfid** — Apple Mobile File Integrity Daemon, системный процесс iOS, проверяющий подписи исполняемых образов.
- **dyld** — динамический линкер macOS/iOS, загружает dylib-ы и резолвит символы.
- **Mach-O** — формат исполняемых файлов Darwin (macOS/iOS).
- **CodeDirectory (CD)** — основная структура подписи, содержит хэши всех страниц бинаря.
- **SuperBlob** — контейнер всех частей подписи (CD + CMS + Entitlements + Requirements).
- **CMS** — Cryptographic Message Syntax (RFC 5652), ASN.1 формат для digital signature.
- **Team ID** — 10-символьный идентификатор Apple Developer team, используется для library validation.
- **Provisioning Profile** — Apple-подписанный XML, привязывающий team ID + app identifier + UDID-ы + entitlements.
- **Developer Mode** — iOS 16+ setting, требуется для запуска dev-signed приложений.
- **JIT** — Just-In-Time compilation (**мы его не используем**).
- **library validation** — политика amfid, требующая одинакового team ID у main app и всех загружаемых dylib-ов.
- **hardened runtime** — macOS политика, требующая entitlements для некоторых операций.

---

Конец документа. Для следующей итерации в другом чате рекомендую стартовать с milestone M1 (секция 9.9).
