# Babelcap — plan and TODO

Updated: 2026-11-25. Legend: `[x]` done and verified · `[~]` written, **not verified on real hardware yet** · `[ ]` not done.
Each stage can be handed to a separate agent. Stages are ordered from the riskiest to the least risky.
After finishing a stage: tick the items, update "Deviations from the spec", commit.

## Status at a glance

| Stage | State |
|---|---|
| 0. Skeleton and tests | ✅ done |
| 1. Spike: de-risk on real hardware | 🟡 in progress — key, WebSocket, system-audio tap, mic transcription and translation seen working; measurements still open |
| 2. MVP (menu bar, key, single source, overlay, HUD) | 🟡 code done, needs verification |
| 3. Two sources and translation | 🟡 code done, needs verification |
| 4. Control panel and customisation | 🟡 code done, needs polish and verification |
| 5. Reliability | 🟡 partly done (mock-server tests exist) |
| 6. Distribution | 🟡 ad-hoc signed pre-release v0.1.0 on GitHub; Developer ID + notarization + Sparkle open |

## Stage 0 — Skeleton (done)

- [x] SwiftPM package, 8 modules, Swift 6, macOS 14.4+, arm64
- [x] Unit tests: `TokenAssembler` (final/draft, speaker change, `<end>`, lagging translation), Soniox config/response models, echo deduper, exporters, settings migration
- [x] `scripts/build_app.sh` / `scripts/install_app.sh` → signed `Babelcap.app` (Info.plist, entitlements, hardened runtime, app icon)
- [x] App launches, control panel and subtitle overlay render (checked with screenshots)

## Stage 1 — Spike: de-risk on real hardware 🟡

Needs a real Soniox key and live audio.

- [x] Key entry (onboarding or Settings → Account); a valid key is accepted, an invalid one is rejected (401). Key format is `snx_proj_…` (≈147 chars)
- [x] Stream to Soniox works: tokens arrive, draft/final text is assembled into the overlay
- [x] Microphone capture + one-way translation to English observed working end to end (screenshot)
- [x] Overlay renders above other windows
- [ ] Onboarding window actually appears on first launch *(not seen in an early screenshot — maybe hidden behind other windows; check `NSApp.activate` for an accessory app)*
- [x] **System audio tap** captures playback (trace shows system RMS > 0 and a live Soniox stream)
- [ ] System audio: the "silent denial" hint fires when permission is refused
- [ ] Microphone: device selection; voice processing does not break capture (check the 9-channel VP format)
- [ ] Measurements: latency to draft (target ≤ 500 ms p50), CPU on M1 (< 5% with two streams), memory (< 150 MB after 2 h)
- [ ] Tap compatibility with App Sandbox (Mac App Store) — find out and record the answer
- [ ] Verify that `CATapDescription(stereoGlobalTapButExcludeProcesses:)` excludes the app's own audio (FR-01)
- [ ] Record real Soniox responses (incl. `<end>` / `<fin>`, `translation_status`, `speaker`) into `Tests/Fixtures/*.json`
- [ ] Overlay above full-screen Zoom/video and in other Spaces

## Stage 2 — MVP

- [x] MenuBarExtra with session timer
- [x] Key in Keychain + live verification on entry (FR-08)
- [~] Single source selectable, Start/Stop, level meter in the HUD
- [~] Captions overlay: NSPanel, `.statusBar`, `canJoinAllSpaces/fullScreenAuxiliary/stationary` (FR-06)
- [~] 3-step onboarding with live level meters (FR-09)

## Stage 3 — Two sources and translation

- [~] Parallel system/mic sessions, "System"/"Mic" labels (FR-03)
- [~] Switch source / mic / apps live without losing history (FR-04): only capture is rebuilt
- [~] One-way / two-way translation per source, Dual mode (FR-11); default is everything → English
- [~] Changing language/context opens the new session before closing the old one
- [~] Voice processing + echo de-duplication (FR-20) — tune the `EchoDeduper` threshold (Jaccard 0.6) on real data
- [~] Mix into one stream (`ChunkMixer`) — check drift / sync between the two inputs
- [x] Both mode stability: voice processing knocked out the concurrent system tap (one input went silent, Soniox "400 No audio received"). VP is now used only when the mic is the sole capture; a watchdog rebuilds any capture that delivers no samples (or a mic stuck at digital zeros) without dropping the Soniox session
- [~] Both mode shows "System" and "Mic" in separate panels by default; split / merge button on the subtitle toolbar
- [ ] AGC / normalisation for quiet signal on multichannel devices (risk from the spec)

## Stage 4 — Control panel and customisation

- [~] HUD: 380×56 capsule, compact pill after 8 s idle (with ✕), expandable with history / search / copy / export (FR-07)
- [~] App picker (per-process tap) with icons (FR-12); bundle IDs are stored
- [~] Settings: Typography, Colors, Layout, Content, Recognition, Translation, Session, Profiles, Account — with live preview (FR-10)
- [~] Modes Captions / Feed / Dual / Split by source (FR-13)
- [~] Profiles with context (terms, domain, translation glossary), JSON import/export (FR-15), presets
- [~] Subtitle panel: movable and resizable by default, hover toolbar, click-through option, shown only while a session runs
- [~] Dock icon (setting), Dock menu, app icon
- [x] Global hotkeys via `RegisterEventHotKey` (FR-16), configurable in Settings → Shortcuts (own recorder, no library), re-registered live
- [ ] Per-speaker colours (currently by source System/Mic only), language tag polish (FR-14)
- [ ] Token-level fade-in (currently segment-level animation)
- [x] Subtitle panel positions remembered per monitor setup; panels/HUD return on-screen when a display is unplugged
- [ ] "Follow the active screen" (FR-21)
- [ ] Honour Reduce Motion / Reduce Transparency in SwiftUI animations (HUD resizing already honours Reduce Motion)
- [ ] Hotkey to expand/collapse the HUD; snapping to edges/corners
- [ ] Verify the Settings window from an accessory-policy app (`showSettingsWindow:` + `NSApp.activate`)
- [ ] Verify dragging / corner-resize of the subtitle panel on real hardware (the grip uses its own `NSView` mouse handling)

## Stage 5 — Reliability

- [~] Reconnect with backoff, keepalive ping, error codes 401/402/408/413/429/5xx (FR-17)
- [~] Session rotation at minute 290
- [x] Mic defaults to the built-in microphone (never an HDMI/dock input that macOS makes the default); "follow the macOS default input" and specific devices are opt-in; an unplugged chosen mic falls back to built-in
- [~] Device changes rebuild only what is affected: output change (HDMI, AirPods) → system tap only (mic only if voice processing is on); default-input change → default mic; chosen mic vanished/returned → mic; sleep/wake → everything. Sessions are kept (test simulates HDMI). Verify with a real HDMI display
- [~] Auto-pause on silence + minutes and cost counter (FR-18)
- [~] Export MD/SRT/JSON (FR-19); optional history in `~/Library/Application Support/Babelcap/History` — **off by default, every session starts clean** (owner decision)
- [x] Mock WebSocket server + tests for 401, 429, reconnect, replay (see "Diagnostics and tests")
- [ ] Mock-server tests for 408 / 413
- [ ] WAV fixtures for `Resampler` / `AudioPump` tests
- [ ] Manual checklist: AirPods ↔ speakers, sleep/wake, full-screen Zoom, two monitors, permission denied
- [ ] 2-hour soak test: memory leaks, drift, CPU

## Stage 6 — Distribution

- [x] GitHub pre-release v0.1.0: ad-hoc signed zip (`scripts/package_release.sh`), install notes incl. Gatekeeper workaround

- [ ] Developer ID signing, hardened runtime (already on), notarization, DMG
- [ ] Sparkle 2 (FR-23)
- [x] App icon; [ ] final product name (open question)
- [ ] Review the recording-consent reminder wording in onboarding

## Stage 7 — Engines, model catalog, downloads, benchmarks

- [x] `SpeechStream` protocol; Soniox, Apple on-device and WhisperKit behind it; engine chosen in settings and switchable live
- [x] Catalog of 23 engines (spec "Real-Time Transcription + Translation: Model Catalog", Nov 2026): price/hour, key + top-up links, languages, translation, size, RAM, licence
- [x] Resumable downloads (HTTP Range, survives restarts), SHA-256 verification, disk-space check, README + manifest per model, delete
- [x] All 7 WhisperKit models downloaded and verified on the dev Mac (≈ 7.7 GB)
- [x] Benchmark clips (EN/RU/DE/FR/ES/IT/HE, macOS voices), WER, speed (× real time) / latency, verdict; `babelcap-bench` CLI; Benchmark tab
- [x] "Models & Providers" window (browse / compare / benchmark), per-provider API keys in the Keychain
- [~] Cloud adapters Gladia, Speechmatics, OpenAI realtime-translate — built from the docs and tested against mock servers; **not yet tried with real keys**
- [~] Cloud adapters Gemini Live Translate (WebSocket, reconnect on `goAway`), ElevenLabs Scribe v3 realtime (+ the local translator),
  Azure Speech Translation (Microsoft Speech SDK, key stored as `region|key`) — Gemini/ElevenLabs tested on mock servers,
  Azure only on token mapping; **none tried with real keys yet**
- [ ] Cloud adapters: Azure Live Interpreter, AssemblyAI, Deepgram (+ a translation step)
- [x] Onboarding: choose cloud (Soniox key) or offline (Whisper turbo + TranslateGemma download)
- [x] Local meeting summary (Qwen3 4B / EuroLLM via MLX); spoken translations played in-process
- [x] Local translation with MLX LLMs (TranslateGemma 4B/12B, Qwen3 4B, EuroLLM 9B) via mlx-swift-lm; translator setting (Auto / Apple / Whisper / model)
- [x] Whisper LocalAgreement-2 streaming: words committed while speaking, sentence-by-sentence translation
- [x] Speaker colours (diarization) in subtitles and history
- [ ] Python sidecar host for SimulStreaming / Voxtral / Hibiki / Seamless
- [ ] Apple engine: auto language detection (it needs a fixed language); show Apple Translation pack status in the catalog
- [ ] Whisper: neural VAD instead of the energy threshold
- [ ] Verify the catalog window on screen (snapshots render off-screen; AppKit controls show as placeholders there)

## Deviations from the spec (deliberate)

1. **Reconnect** is implemented as a *new* Soniox session + audio replay from the last finalised position
   (`absFinalMs`), not via `reconnect_url` / `reconnect_token` / `last_seq` — the protocol details were not verified.
   `enable_reconnect` is not sent. If the protocol is confirmed, switch to it (less loss, no extra concurrency slot).
2. **RingBuffer** is not strictly lock-free: `os_unfair_lock` with `try_lock` on the producer side (on contention samples are dropped, the audio thread never blocks).
3. **Hotkeys** are fixed, without the KeyboardShortcuts library.
4. **History** is JSON files, not SwiftData/SQLite.
5. Extra modules `CaptionsCore` and `AppSettings`; `SettingsView` lives in the app target (it needs `CaptionView` for the live preview).
6. Not implemented: Sparkle, TTS (FR-22), configurable hotkeys, follow-active-screen.
7. Translation is attached to segments by its own cursor (it is not aligned 1:1 with the original) — a heuristic, verify on real responses.
8. Voice processing is disabled while system audio is captured at the same time (it conflicts with the tap); echo is handled by headphones + de-duplication.
9. Defaults differ from the spec: everything is translated to English out of the box, the Dock icon is shown (setting), "System/Mic" labels are off, the subtitle panel is movable (not click-through) by default.
10. **Azure** goes through Microsoft's Speech SDK (`speech-sdk-spm`, a binary framework embedded in `Contents/Frameworks`),
    not a hand-written WebSocket client: the Azure speech-translation WebSocket protocol is not documented.
    Ad-hoc builds sign the app with `Resources/Babelcap-adhoc.entitlements` (adds `disable-library-validation`), because an
    ad-hoc app has no Team ID and dyld would refuse the Microsoft-signed framework.

## Open product questions (from the spec)

- [ ] Distribution: personal use / Developer ID / Mac App Store?
- [ ] BYOK for everyone, or a backend with temporary Soniox keys and billing later?
- [ ] Minimum macOS: 14.4 (now) or 15+?
- [ ] Default mode: two streams or one mixed stream?
- [ ] First-run language pairs and profiles (now: Default (→ English), Call RU↔EN, Meetup HE→EN, Video EN→RU)
- [x] Keep history by default? **No** — each session starts from zero; saving is opt-in
- [ ] Auto-pause: after how many minutes of silence (now: 5)
- [x] Final name: **Babelcap** (25 Nov 2026; the working title Subveil was already taken). Old data — settings, models, Keychain items, window frames — is migrated on first launch (`LegacyMigration`, `KeychainStore.legacyService`)
- [ ] Translation voice-over (Soniox TTS) and LLM meeting summaries — wanted later?

## Diagnostics and tests

- Trace log: `~/Library/Logs/Babelcap/trace.log` (also `log stream --predicate 'subsystem == "app.babelcap"'`). It records states, codes, counters and levels — **never the API key or transcript text**. Follow it with `tail -f ~/Library/Logs/Babelcap/trace.log`.
- Automated tests (`swift test`, 63 tests, incl. off-screen HUD layout checks): token assembly; Soniox models; `SonioxSession` against a local mock WebSocket server (Bearer header, config without `api_key`, 401 without reconnect, 429 backoff, reconnect + replay + timestamp offset); the whole engine with a fake capture (start, audio flow, transcript, pause/resume, translation change without losing history, 401, missing key); Keychain (isolated service name); settings defaults and migration.
- [ ] UI / onboarding tests (XCUITest or snapshots); `SystemAudioTap` / `MicCapture` tests on hardware (not possible in CI)

## Repository / README

- [x] Public repository https://github.com/alexey-a-abramov/babelcap, README in English, MIT license
- [x] README screenshot: video with live translation (`docs/images/demo-video-translation.jpg`)
- [ ] More screenshots: System/Mic/Both switching in the HUD, expanded HUD, appearance settings, target-language-only mode
- [ ] CI (GitHub Actions, macOS runner: `swift test`)

## Log

- 2026-11-24 — Configurable global shortcuts; positions per monitor setup.

- 2026-11-24 — Gladia, Speechmatics and OpenAI realtime-translate adapters (mock-tested); onboarding engine choice; local meeting summary; spoken translations.

- 2026-11-24 — Fully local pipeline: Whisper (LocalAgreement streaming) + TranslateGemma via MLX, RU/HE/EN at 11–14× real time; app now built with xcodebuild (Metal shaders); speaker colours.

- 2026-11-24 — Release v0.1.0 (alpha, ad-hoc signed) published on GitHub.

- 2026-11-24 — Multi-engine support: model catalog window, resumable verified downloads into the app folder, Apple on-device and WhisperKit engines, benchmark clips + CLI.

- 2026-11-23 — Target language can be changed mid-session from the subtitle toolbar (globe menu), the menu bar ("Translate to") or the HUD; one settings watcher swaps only streams whose Soniox config changed. Targeted device-change handling for HDMI / AirPods.

- 2026-11-23 — Both mode: VP/tap conflict found in traces and fixed, capture watchdog, separate System/Mic panels by default with split/merge toggle.

- 2026-11-23 — Subtitles show only the target language by default; fixed-size panel (lines fade out at the top), drag anywhere with snapping, resize from any edge; no history by default; simplified README around use cases.

- 2026-11-23 — Stage 0: skeleton, all modules, tests, `.app` build, launch.
- 2026-11-23 — Root cause of "API key required": an item created with `security add-generic-password` triggers a Keychain access dialog, and the read on launch blocked the app. The key is now read off the main thread, existence is checked without a prompt, and builds are signed with a stable Apple Development identity.
- 2026-11-23 — Key accepted by Soniox; mic transcription with translation to English observed working.
- 2026-11-23 — HUD polish: status badge (ready / live + timer / paused / error), icon source picker with built-in level meters, unified buttons; off-screen layout tests. System-audio capture confirmed live.
- 2026-11-23 — HUD: ✕ button, gear menu (Settings / Hide / Quit); subtitle panel movable + resizable with hover toolbar and shown only during sessions; Dock icon + app icon; defaults translate to English; public GitHub repo with README and MIT license.
