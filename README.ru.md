# zigbox

> 🇬🇧 English version: **[README.md](README.md)**

Экспериментальный проект: приложение, которое **динамически компилирует и запускает Zig-код в рантайме** на всех основных платформах — Windows, Linux, macOS, Android, и (самое интересное) iOS без jailbreak.

Статус: **ранняя стадия, исследование**. Цель — разобраться, насколько такое реально построить, и что из этого получится.

---

## 🤖 Для ИИ-агентов, читающих этот репозиторий

**Прежде чем браться за любую задачу — обязательно прочитайте файл `docs/zig-runtime-compilation-plan.ru.md` полностью, если вы его ещё не читали в этом сессии.**

Там:

- история принятых архитектурных решений (чтобы не переигрывать их заново);
- детальный план по каждой из пяти целевых ОС;
- углублённая секция по iOS со всеми нюансами подписи, `amfid`, entitlements и `dlopen`;
- список известных подводных камней;
- ссылки на ключевую документацию (Apple Technotes, Zig internals, signing references);
- глоссарий терминов.

Без этого контекста вы, скорее всего, предложите один из уже отклонённых подходов (WASM, JIT, server-compile) и потратите время впустую. План большой, но он единственный источник истины по проекту.

После прочтения — можно переходить к конкретному milestone из раздела 9.9 документа или к задаче из TODO ниже.

---

## О чём это

Идея: взять Zig-исходник от пользователя (из редактора, файла, сети, REPL — откуда угодно), прогнать через Zig-компилятор, слинкованный внутрь приложения, получить нативный бинарь под текущую платформу, загрузить его и выполнить. Пользовательский код получает **полный доступ к платформенным API** — UIKit на iOS, JNI/Activity на Android, WinAPI/Cocoa/X11 на десктопе, потокам, сокетам, файловой системе.

Текущая реализация разделяется так:

- **Linux / macOS:** вызывается upstream `mainArgs()` прямо in-process.
- **Windows:** компилятор всё ещё слинкован в `zigbox.exe`, но запускается через self-reexec этого же бинаря во внутреннем режиме `__zigbox-zig`. Это изолирует upstream-вызовы `std.process.exit(...)` и сохраняет работоспособность внутреннего multi-tool dispatch Zig (`lld-link`, `dlltool`, `cc`, `-cc1`, ...).
- **Целевая схема для iOS:** по-прежнему pure in-process. Windows subprocess-слой сейчас только временный desktop-workaround для M1, а не финальный архитектурный принцип.

То есть текущий desktop prototype **не зависит от внешнего `zig.exe` в рантайме**, но на Windows это пока ещё не strict same-process implementation.

Главный вызов — **iOS**. Apple формально запрещает запуск неподписанного кода, но подпись — это криптографический алгоритм, а не привилегия. Если в приложении есть приватный ключ dev-сертификата, подпись можно сделать прямо на устройстве, и `amfid` такой dylib примет. Подробности и ограничения — в плане.

Это личный исследовательский проект, **не предназначенный для дистрибуции через магазины** и не претендующий на production-качество.

---

## Поддержка платформ

| Платформа | Подход | Статус |
|---|---|---|
| Windows (x86_64) | Zig → DLL → `LoadLibrary` | 🔲 Не начато |
| Linux (x86_64, aarch64) | Zig → SO → `dlopen` | 🔲 Не начато |
| macOS (arm64 + x86_64) | Zig → dylib → `dlopen` | 🔲 Не начато |
| Android (arm64, API 26+) | Zig → SO → `System.load` через JNI | 🔲 Не начато |
| iOS (arm64, 16+) | Zig → dylib → on-device sign → `dlopen` | 🔲 Не начато |

---

## Быстрый старт

В репозитории уже есть ранний desktop prototype. Финальный публичный API по-прежнему ожидается примерно таким:

```zig
// будущий пример использования
const source = @embedFile("user_code.zig");
var runtime = try zigbox.Runtime.init(allocator, .{});
defer runtime.deinit();

const module = try runtime.compile(source);
const entry = try module.lookup("entry", fn () void);
entry();
```

---

## Грубый TODO

Milestone-разметка соответствует разделу 9.9 плана (iOS), плюс отдельные шаги для остальных платформ.

### Фаза 1 — десктоп (proof of concept)
- [x] Скелет приложения на Zig с проектом `build.zig`.
- [x] Встроить Zig-компилятор как static library, вариант А (CLI-as-library), см. план 4.2.
  - Upstream Zig подключается как git submodule в `deps/zig`.
  - `patches/zig-expose-lib.patch` добавляет artifact `libzig` в `build.zig` upstream'а (один аддитивный блок, без правки существующих строк — переживает апгрейды).
  - `scripts/setup-zig-source.sh` клонирует, применяет патч, собирает `libzig.a`.
  - Наш `build.zig` линкует `libzig` в хост и импортирует upstream `src/main.zig` как Zig-модуль.
  - Linux/macOS сейчас вызывают `mainArgs()` напрямую in-process.
  - Windows сейчас делает self-reexec того же `zigbox.exe` во внутреннем режиме `__zigbox-zig`, чтобы изолировать upstream `std.process.exit(...)` и поддержать внутренний multi-tool dispatch Zig (`lld-link`, `dlltool`, `cc`, `-cc1`, ...).
- [ ] **M1.5** — заменить вызовы `std.process.exit` в embedded компиляторе на recoverable errors, чтобы ошибки компиляции не убивали хост. Linux/macOS всё ещё требуют этого для устойчивого pure in-process пути; Windows пока использует self-reexec как временный desktop-workaround.
- [ ] Linux: компиляция + `dlopen` + `dlsym` простейшего `entry()` — код готов, end-to-end ещё не проверен.
- [x] Windows: то же через `LoadLibrary` — проверено через `zig build smoke` на Windows/MSVC с LLVM-enabled libzig и `zigbox-host.lib`.
- [ ] macOS: то же через `dlopen` — код готов, не проверено.
- [x] Host bridge API (C ABI): `host_log`, `host_greet` в `src/bridge.zig`. `host_ui_alert` / `host_http_get` — на Фазу 6.

Локальная проверка M1:

**Linux / macOS:**

```bash
# Важно: bootstrap zig должен совпадать с выбранной upstream-версией.
# По умолчанию `supported` = проверенная версия проекта (сейчас 0.14.0).

# Один раз: клон upstream Zig, применение патча, сборка libzig.a (~минуты).
./scripts/setup-zig-source.sh

# То же, но с автоматической загрузкой matching bootstrap Zig:
ZIG=auto ./scripts/setup-zig-source.sh

# Явно выбрать конкретную поддерживаемую версию:
ZIG_TAG=0.14.0 ZIG=auto ./scripts/setup-zig-source.sh

# Взять latest stable с ziglang.org:
ZIG_TAG=latest-stable ZIG=auto ./scripts/setup-zig-source.sh

# Экспериментально: latest master snapshot.
ZIG_TAG=master ZIG=auto ./scripts/setup-zig-source.sh

# End-to-end компиляция + dlopen + вызов:
zig build smoke

# Или интерактивно с другим примером:
zig build run -- examples/use_bridge.zig
```

**Windows (PowerShell):**

```powershell
# Важно: bootstrap zig должен совпадать с выбранной upstream-версией.
# По умолчанию `supported` = проверенная версия проекта (сейчас 0.14.0).

# Для генерации Windows DLL сейчас нужен libzig, собранный с LLVM.
# Точные LLVM-пути зависят от вашей машины.
.\scripts\setup-zig-source.ps1 `
  -Tag 0.14.0 `
  -Target x86_64-windows-msvc `
  -EnableLlvm `
  -ConfigH C:\path\to\zig\config.h `
  -SearchPrefix C:\path\to\llvm

# То же, но с автоматической загрузкой matching bootstrap Zig:
.\scripts\setup-zig-source.ps1 `
  -Tag 0.14.0 `
  -Zig auto `
  -Target x86_64-windows-msvc `
  -EnableLlvm `
  -ConfigH C:\path\to\zig\config.h `
  -SearchPrefix C:\path\to\llvm

# Явно выбрать конкретную поддерживаемую версию:
.\scripts\setup-zig-source.ps1 -Tag 0.14.0 -Zig auto

# Взять latest stable с ziglang.org:
.\scripts\setup-zig-source.ps1 -Tag latest-stable -Zig auto

# Экспериментально: latest master snapshot.
.\scripts\setup-zig-source.ps1 -Tag master -Zig auto

# setup-скрипт в конце печатает путь до libzig. Для LLVM-enabled
# Windows-сборки нужно также сообщить zigbox-сборке про LLVM и zigcpp:
zig build smoke `
  -Dtarget=x86_64-windows-msvc `
  -Dembedded-zig-have-llvm=true `
  -Dembedded-zig-zigcpp=C:\path\to\zigcpp\zigcpp.lib `
  -Dlibzig="deps\zig\zig-out\lib\zig.lib" `
  --search-prefix C:\path\to\llvm
```

Известные Windows-нюансы (идут в milestone'ы M1.5 / M1.6):

- **Runtime path split.** Linux/macOS сейчас используют `mainArgs()` прямо in-process. Windows сейчас использует self-reexec `zigbox.exe` во внутреннем режиме `__zigbox-zig`. Это сохраняет runtime независимым от внешнего `zig.exe`, но пока остаётся subprocess-workaround, а не финальной M1.5-архитектурой.
- **Host import library на Windows.** `build.zig` генерирует `zigbox-host.lib` через `zig dlltool`, и embedded compiler автоматически линкует user DLL против него. Это Windows-замена паттерну `rdynamic` из ELF/Mach-O.
- **Хост и libzig должны иметь одинаковый ABI.** Если upstream Zig у тебя собирает libzig как `windows-msvc`, хост тоже должен собираться под `windows-msvc`; MinGW и MSVC-библиотеки не смешиваются. Явная форма: `zig build -Dtarget=x86_64-windows-msvc`.
- **Для Windows нужен LLVM-enabled `libzig`.** Upstream COFF self-hosted backend из Zig 0.14.0 пока не умеет генерировать нужный dynamic-library output для этого проекта, поэтому Windows сейчас требует `-EnableLlvm` на этапе setup и `-Dembedded-zig-have-llvm=true` на этапе `zig build`.

### Фаза 2 — Android
- [ ] Gradle-проект с JNI-мостом к Zig-хосту.
- [ ] Сборка Zig-компилятора под `aarch64-linux-android`.
- [ ] Kotlin-обёртка `ZigRuntime` (пример в плане, 8.4).
- [ ] Проверить работу на API 29+.

### Фаза 3 — iOS M1: dlopen работает
- [ ] iOS-проект в Xcode с включённым Developer Mode на устройстве.
- [ ] Собрать простейший тестовый dylib заранее, положить в bundle.
- [ ] Убедиться что `dlopen`/`dlsym` работают с bundle-dylib.
- [ ] Свайп мыслей по логам `amfid` через Console.app.

### Фаза 4 — iOS M2: on-device подпись
- [ ] Интегрировать `ldid` (ProcursusTeam fork) как static library.
- [ ] Альтернатива: начать собственный signer по псевдокоду из плана (приложение B) — только если ldid не соберётся.
- [ ] Встроить dev-cert в формате PKCS#12 как encrypted asset.
- [ ] Pipeline: bundle-unsigned-dylib → подписать локально → переподписанный dylib → `dlopen`.
- [ ] Сравнить результирующий Mach-O с `codesign`-подписанным побайтово (для отладки формата).

### Фаза 5 — iOS M3: on-device компиляция
- [ ] Подключить Zig-компилятор для iOS.
- [ ] Сборка с `-fno-llvm` чтобы уменьшить размер бинаря.
- [ ] Pipeline: source → compile → unsigned dylib → sign → dlopen.
- [ ] Инкрементальная компиляция / cache.

### Фаза 6 — полный pipeline + UI
- [ ] UI для ввода исходника (iOS, Android, desktop).
- [ ] Примеры user-кода: hello-world с alert, HTTP-запрос, простое рисование.
- [ ] Замеры: время компиляции, размер бинаря, использование памяти.

### Фаза 7 — опциональные расширения
- [ ] WASM fallback для iOS App Store (если вдруг захочется публиковать).
- [ ] Hot-reload при изменении исходника.
- [ ] Syntax highlighting / LSP для встроенного редактора.

---

## Помощь и обратная связь

Автор **не специалист по Zig** и никак не претендует на экспертность — это личный исследовательский эксперимент, проба пера. Если у вас есть идеи, поправки, критика архитектуры, или вы видите, где я явно что-то недопонимаю — пишите issue или PR, буду рад любому диалогу.

Особенно ценная обратная связь:

- опыт работы с внутренним API Zig-компилятора (Compilation.zig, Module.zig);
- реальные кейсы on-device code signing на современных iOS (18, 26);
- подсказки по работе с `ldid` под iOS target;
- знание тонкостей amfid / library validation в актуальных iOS;
- паттерны архитектуры host-bridge для кроссплатформенных скриптовых runtime-ов.

Если вы пробовали похожее и у вас **не получилось** — это тоже ценно, расскажите где упёрлись.

---

## Инструменты разработки

Проект активно пользуется помощью ИИ-агентов. В работе применялись/применяются:

- **Claude Opus 4.7** — архитектурные обсуждения, глубокие технические разборы.
- **Claude Sonnet 4.6** — рутинные задачи, документация, ревью кода.
- **GPT-5.4 High** — кросс-проверка подходов, альтернативные точки зрения.
- **Gemini 3.1 Pro** — работа с большими контекстами, поиск по документации.

Если вы ИИ-агент, работающий над этим проектом в новом чате — ещё раз напоминание: **сначала прочтите `docs/zig-runtime-compilation-plan.ru.md`**. Без него любые решения будут некорректными.

---

## Ключевые документы

- **[docs/zig-runtime-compilation-plan.ru.md](docs/zig-runtime-compilation-plan.ru.md)** — основной план проекта, прочитать в первую очередь.
- [README.md](README.md) — английская версия этого файла.
- README.ru.md (этот файл) — быстрое введение на русском.

---

## Дисклеймер

Проект:

- находится в исследовательской стадии; пока есть только ранний desktop prototype;
- рассчитан на личные устройства автора, не на дистрибуцию;
- использует dev-сертификат Apple, что формально — граница терминов Apple Developer License Agreement (private key в билде). Оправдано характером проекта (собственные устройства автора, нет третьих лиц), но если вы форкаете — осознавайте риски для своего dev-аккаунта;
- не гарантирует, что подход будет работать в следующих версиях iOS — Apple регулярно ужесточает проверки подписи, и on-device signing может однажды перестать проходить.

Всё делается на свой страх и риск.
