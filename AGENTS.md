# Subveil — контекст для агентов

Нативное macOS-приложение (Apple Silicon, macOS 14.4+): живые субтитры + перевод поверх всех окон.
Системный звук (Core Audio process tap) и/или микрофон → Soniox `stt-rt-v6` (WebSocket) → плавающий оверлей.
Исходная спецификация — «Live Captions для macOS» (23 Nov 2026); рабочее имя продукта здесь **Subveil**.

> **Как работать с этим репо.** Источник правды о ходе работ — [`docs/TODO.md`](docs/TODO.md).
> Взял этап → сделал → отметил `[x]`, обновил «Статус» и «Отклонения от спецификации» → закоммитил.
> Не ломай то, что уже отмечено `[x]`; новые решения, отличающиеся от спеки, пиши в TODO.md.

## Ключевые решения (не менять без причины)

- Swift 6 (strict concurrency), SwiftUI для настроек/HUD/оверлея, AppKit для окон. Без Obj-C/Electron/Tauri.
- Системный звук: `CATapDescription` + `AudioHardwareCreateProcessTap` + private aggregate device. Без BlackHole.
- Микрофон: `AVAudioEngine`, опционально voice processing с минимальным ducking.
- Два независимых потока Soniox (system «Them» / mic «Me»); опция «Mix into one stream» (`.mixed`).
- Перевод — блок `translation` в той же сессии Soniox (one_way / two_way). Отдельного сервиса нет.
- Ключ — только Keychain, заголовок `Authorization: Bearer`, **не** `api_key` в конфиге. Ключ не попадает в логи/профили.
- Аудио на диск не пишется. В логах (`os.Logger`) нет текста транскриптов.
- На real-time потоке (IOProc / tap) только копирование в ring buffer: без аллокаций и Swift concurrency.
- BYOK, своего бэкенда нет. Metal не нужен.

## Структура (SwiftPM, `Package.swift`)

| Модуль | Назначение |
|---|---|
| `AudioCapture` | `SystemAudioTap`, `MicCapture`, `RingBuffer`, `Resampler` (→16 kHz s16le, чанки 3200 Б), `AudioPump` (actor), `DeviceMonitor`, список устройств/процессов |
| `SonioxClient` | `SonioxSession` (actor: connect, reconnect, ping, ротация 290 мин, replay), Codable-модели, `SonioxError`, `SonioxKeyVerifier`, `SourceKind` |
| `Transcript` | `TokenAssembler` (две дорожки original/translation), `TranscriptStore` (@MainActor, ≤1 обновление/кадр), `EchoDeduper`, `Exporters` (MD/SRT/JSON) |
| `AppSettings` | `Profile` и вложенные настройки, `SettingsStore`, `KeychainStore`. *(не `Settings` — конфликт с SwiftUI)* |
| `CaptionsCore` | `CaptionsEngine` — оркестрация: рантаймы источников, сессии, переключение на лету, автопауза, стоимость, события устройств, `LevelProbe` |
| `Overlay` | `CaptionView` (Captions/Feed/Dual/Split), `CaptionPanel` + `OverlayController` |
| `ControlHUD` | `ControlView` + `ControlPanelController` (капсула, pill, раскрытие, история) |
| `Subveil` (exec) | `@main`, `MenuBarExtra`, `AppContext`, `SettingsView`, `OnboardingView`, `HotKeys` (Carbon) |

Отличия от спеки: добавлены `CaptionsCore` (чтобы Overlay/HUD не зависели друг от друга) и `AppSettings`;
`SettingsView` живёт в app-таргете (ему нужен `CaptionView` для живого превью).

## Команды

```bash
swift build                       # отладочная сборка
swift test                        # юнит-тесты (TokenAssembler, модели Soniox, дедупер, экспорт)
scripts/build_app.sh              # release → build/Subveil.app (ad-hoc подпись, hardened runtime)
scripts/build_app.sh "Developer ID Application: …"   # для распространения
open build/Subveil.app
```

Ad-hoc подпись меняется с каждой сборкой → macOS может заново спрашивать разрешения (микрофон, System Audio Recording).
Для стабильных TCC-разрешений при разработке подписывай постоянным сертификатом.

## Правила

- Атомарные коммиты; тесты перед пушем; не коммитить `.env`, ключи, `data/`, `logs/`, `build/`.
- Токены/ключ Soniox никогда не логировать и не класть в тесты.
- Контракт Soniox (формат ответов, коды ошибок) трактовать толерантно: неизвестные поля игнорировать.
- Новая логика сборки текста — сначала тест на записанных JSON-ответах.
- UI-изменения проверять запуском приложения (скриншот), не только сборкой.

## Известные подводные камни

- `ContentMode`, `Settings` — имена конфликтуют со SwiftUI (поэтому `ContentDisplay`, `AppSettings`).
- Отказ в разрешении на системный звук = tap отдаёт нули без ошибки → детектор в `CaptionsEngine.tick`.
- Ducking от voice processing; на многоканальных устройствах возможен тихий сигнал (нужен AGC — см. TODO).
- BSD `sed` на macOS не поддерживает `\b` — использовать `perl -pi -e`.
