# Subveil — context for agents

Native macOS app (Apple Silicon, macOS 14.4+): live captions + translation floating above all windows.
System audio (Core Audio process tap) and/or microphone → Soniox `stt-rt-v6` (WebSocket) → always-on-top overlay.
The product was specified as "Live Captions for macOS" (23 Nov 2026); the working product name is **Subveil**.

> **How to work in this repo.** The source of truth for progress is [`docs/TODO.md`](docs/TODO.md).
> Pick a stage → implement → tick the items, update "Status" and "Deviations from the spec" → commit.
> Do not break items already ticked `[x]`. Write any decision that differs from the spec into TODO.md.
> Documentation is written in **English**.

## Key decisions (do not change without a reason)

- Swift 6 (strict concurrency); SwiftUI for settings/HUD/overlay content, AppKit for windows. No Objective-C, Electron or Tauri.
- System audio: `CATapDescription` + `AudioHardwareCreateProcessTap` + private aggregate device. No BlackHole.
- Microphone: `AVAudioEngine`, optional voice processing with minimal ducking.
- Two independent Soniox streams (labelled "System" / "Mic"); optional "Mix into one stream" (`.mixed`).
- Translation is the `translation` block of the same Soniox session (one_way / two_way) — no separate service.
  Default: everything is translated to English.
- The API key lives only in the Keychain and is sent as `Authorization: Bearer` — **not** `api_key` in the config.
  It never reaches logs or exported profiles.
- Audio is never written to disk. Logs (`os.Logger` + `~/Library/Logs/Subveil/trace.log`) never contain transcript text.
- On real-time threads (IOProc / engine tap) only copy into the ring buffer: no allocation, no locks, no Swift concurrency.
- BYOK, no backend. Metal is not needed.

## Structure (SwiftPM, `Package.swift`)

| Module | Purpose |
|---|---|
| `AudioCapture` | `SystemAudioTap`, `MicCapture`, `RingBuffer`, `Resampler` (→ 16 kHz s16le, 3200-byte chunks), `AudioPump` (actor), `DeviceMonitor`, device/process lists |
| `SonioxClient` | `SonioxSession` (actor: connect, reconnect, ping, 290-min rotation, replay), Codable models, `SonioxError`, `SonioxKeyVerifier`, `SourceKind`, `Trace` |
| `Transcript` | `TokenAssembler` (separate original/translation tracks), `TranscriptStore` (@MainActor, ≤ 1 update per frame), `EchoDeduper`, `Exporters` (MD/SRT/JSON) |
| `AppSettings` | `Profile` and nested settings, `SettingsStore`, `KeychainStore`. *(Not named `Settings` — clashes with SwiftUI.)* |
| `LocalEngines` | On-device engines behind `SpeechStream`: `AppleSpeechStream` (SpeechAnalyzer, macOS 26), `WhisperKitStream` (+ `WhisperKitPool`: one loaded model, serialised inference), `AppleTranslator` |
| `LocalLLM` | MLX (mlx-swift-lm 3.33): `MLXRunner` (one loaded LLM, stops at end-of-turn), `MLXTranslator` (TranslateGemma prompt or chat) |
| `CloudEngines` | WebSocket adapters: Gladia, Speechmatics, OpenAI realtime-translate, Gemini Live Translate, ElevenLabs Scribe (+ local translator) |
| `AzureEngine` | Azure Speech Translation via Microsoft's Speech SDK (binary framework) |
| `ModelHub` | `ModelCatalog` (all cloud + local engines, prices, URLs, sizes, RAM), `ModelDownloads` (resumable HTTP Range, SHA-256), `ModelStorage` (`~/Library/Application Support/Subveil/Models/<id>`), `EngineFactory`, `BenchmarkRunner` + clips + WER |
| `CatalogUI` | "Models & Providers" window: browse / compare / benchmark |
| `SubveilBench` (exec) | `subveil-bench` CLI: list, download, test engines |
| `CaptionsCore` | `CaptionsEngine` — orchestration: source runtimes, sessions, live switching, auto-pause, cost, device events, `LevelProbe` |
| `Overlay` | `CaptionView` (Captions/Feed/Dual/Split), `CaptionPanel` + `OverlayController` (movable/resizable panel, click-through, shown only while a session runs) |
| `ControlHUD` | `ControlView` + `ControlPanelController` (capsule, pill, expansion, history) |
| `Subveil` (executable) | `@main`, `MenuBarExtra`, Dock icon, `AppContext`, `SettingsView`, `OnboardingView`, `HotKeys` (Carbon) |

Differences from the spec: `CaptionsCore` was added so Overlay and HUD do not depend on each other, plus `AppSettings`;
`SettingsView` lives in the app target (it needs `CaptionView` for the live preview).

## Commands

```bash
swift build                       # debug build
swift test                        # 63 tests: token assembly, Soniox models, mock WebSocket server, engine end-to-end, Keychain, settings
scripts/build_app.sh              # release → build/Subveil.app (signed, hardened runtime)
scripts/install_app.sh            # build + sign + install to ~/Applications/Subveil.app + launch
scripts/install_app.sh "<identity>"   # use a specific signing identity (e.g. Developer ID)
scripts/build_app.sh                # xcodebuild: MLX needs its Metal shaders (swift build cannot compile them)
xcodebuild -scheme subveil-bench -configuration Release -destination 'platform=macOS,arch=arm64' -derivedDataPath .build/xcode -skipPackagePluginValidation -skipMacroValidation build
.build/xcode/Build/Products/Release/subveil-bench test whisperkit-large-v3-turbo --clip he --translator mlx-translategemma-4b
swift run subveil-bench list                       # catalog + what is installed
swift run subveil-bench download whisperkit-large-v3-turbo
swift run subveil-bench test ready --clip ru --target en   # every ready engine on the Russian clip
swift scripts/make_icon.swift && iconutil -c icns build/AppIcon.iconset -o Resources/AppIcon.icns   # regenerate the icon
tail -f ~/Library/Logs/Subveil/trace.log   # live diagnostics
```

Signing: the build scripts use the first *Apple Development* identity in the keychain, otherwise ad-hoc. A stable identity
keeps the designated requirement constant, so Keychain / Microphone / System Audio permissions survive rebuilds.
An ad-hoc signature changes with every build and makes macOS ask again.

## Rules

- Atomic commits; run `swift test` before pushing; never commit `.env`, keys, `data/`, `logs/`, `build/`.
- Never log or print the Soniox key or transcript text; never put a key in tests (tests use a mock server and an isolated Keychain service).
- Treat the Soniox contract (response shapes, error codes) tolerantly: ignore unknown fields.
- New text-assembly logic starts with a test over recorded JSON responses.
- Verify UI changes by launching the app (screenshot), not only by building.
- Tests must never touch the user's real settings, Keychain item or history — use the injectable `SettingsStore(directory:keychain:)`,
  `captureFactory` / `endpoint` seams on the engine, and `saveHistory = false`.

## Known pitfalls

- `ContentMode` and `Settings` clash with SwiftUI (hence `ContentDisplay`, `AppSettings`).
- Permission denial for system audio = the tap delivers zeros with no error → detector in `CaptionsEngine.tick`.
- A Keychain item created by the `security` CLI makes macOS show an access dialog to the app; reading the secret blocks until answered,
  so it is read off the main thread, and presence is checked with `KeychainStore.exists()` (no prompt).
- Voice processing ducks other audio; multichannel devices may give a quiet signal (AGC is still a TODO).
- BSD `sed` on macOS has no `\b` — use `perl -pi -e`.
- Every engine speaks `SpeechStream` and emits Soniox-style tokens (final/non-final, original/translation, `<end>`), so the
  transcript assembler and UI are engine-agnostic. New adapters: implement `SpeechStream`, set `engine` on the catalog entry.
- WhisperKit finds `tokenizer.json` in the model folder; the catalog downloads it there so nothing lands in a hidden cache.
- MLX: `swift build` / `swift run` cannot compile Metal shaders → "Failed to load the default metallib". Build with xcodebuild
  (the app script does); the metallib ships inside `mlx-swift_Cmlx.bundle` in Contents/Resources (never in Contents/MacOS —
  codesign rejects non-code there). Apple Translation works only inside the app bundle, not from the CLI.
- TranslateGemma does not declare `<end_of_turn>` as EOS: generation is stopped by token id in `MLXRunner`.
- Soniox keys look like `snx_proj_…` (long, with `.`, `_`, `-`); a wrong key gives `401 Incorrect API key provided`.
- Azure Speech SDK is a binary framework: `build_app.sh` copies it to `Contents/Frameworks`, adds the `@executable_path/../Frameworks`
  rpath and re-signs it. Ad-hoc builds need `Resources/Subveil-adhoc.entitlements` (`disable-library-validation`), otherwise
  dyld fails with "different Team IDs". The Azure credential is stored as `region|key` in the provider's Keychain item.
