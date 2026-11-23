<p align="center"><img src="docs/images/icon.png" width="112" alt="Subveil icon"></p>

<h1 align="center">Subveil</h1>

<p align="center">
Live captions and live translation for macOS — from your system audio, your microphone, or both.<br>
Native Swift, always-on-top subtitles, powered by <a href="https://soniox.com">Soniox</a> real-time speech recognition.
</p>

> **Status: early alpha.** It builds, passes its automated tests and runs, but it has had little real-world testing.
> Expect rough edges. See [docs/TODO.md](docs/TODO.md) for exactly what is verified and what is not.

## What it does

Subveil listens to what your Mac plays (calls, videos, webinars, streams) and/or what your microphone hears,
transcribes it in real time, optionally translates it, and shows the result as subtitles floating above every
window — including full-screen apps.

By default **everything is translated to English**: speak or listen in any language, read English.

## Highlights

- **Two independent sources, one switch.** Capture *System* audio, the *Mic*, or *Both* — and change it live from the
  control panel, without stopping the session or losing the transcript. Each source has its own Soniox stream, so
  the other side of a call ("Them") and your own voice ("Me") never get mixed up. Prefer a single stream? Flip
  *Mix into one stream*.
- **Live translation, per source.** One-way (any language → English, Russian, Hebrew, …) or two-way (RU ⇄ EN) conversation
  mode, configured separately for system audio and microphone. Show the original, the translation, or both stacked.
  Changing the language opens a new session *before* closing the old one, so captions don't blink out.
- **Per-app capture.** Listen to just one app (say, your browser) so notifications and music stay out of the
  transcript. No virtual audio driver needed: Subveil uses Core Audio process taps (macOS 14.4+).
- **Subtitles that stay out of your way.** A borderless panel above all windows and Spaces, including full-screen
  video and Zoom. Drag it anywhere, resize it from the corner, or make it click-through. It disappears when the
  session ends.
- **Draft vs. final text.** Words appear as they are recognised (draft style) and settle when the sentence is final.
  Right-to-left languages (Hebrew, Arabic) align automatically.
- **Fully customisable look.** Font, size, colours, background, blur, outline, shadow, number of lines, feed or
  caption mode, optional "Them / Me" labels — with a live preview. Save everything as named profiles and share them as JSON.
- **Accuracy knobs.** Per-profile language hints, domain description, custom terms and a translation glossary
  (Soniox context) — the biggest lever for names and jargon.
- **Cost-aware.** Session timer and running cost estimate in the panel and the menu bar; automatic pause after
  N minutes of silence (the session reopens on the first voice).
- **Resilient.** Reconnects with exponential backoff and replays the unfinalised audio, rotates sessions before
  Soniox's 300-minute limit, and follows output-device changes (AirPods, HDMI) and sleep/wake.
- **History and export.** Searchable session history; export to Markdown, SRT or JSON.
- **Global hotkeys** (no Accessibility permission): `⌥⌘Space` start/stop, `⌥⌘P` pause, `⌥⌘H` control panel,
  `⌥⌘C` subtitles, `⌥⌘L` movable ⇄ click-through, `⌥⌘S` cycle sources, `⌥⌘T` translation on/off.

## Privacy

- Audio goes **only to Soniox**, over TLS. Nothing is recorded to disk.
- You bring your own Soniox API key; it is stored in the macOS **Keychain** and never written to logs or exported profiles.
- Transcript history is local (`~/Library/Application Support/Subveil`) and can be turned off.
- Diagnostics (`~/Library/Logs/Subveil/trace.log`) contain states and counters — never the key or transcript text.
- The recording indicators of macOS are not hidden. Recording other people's conversations may require their consent.

## Requirements

- Apple Silicon Mac, **macOS 14.4+**
- Xcode 26 / Swift 6 toolchain to build from source
- A [Soniox](https://soniox.com) API key (real-time recognition is billed by session time —
  roughly $0.12/h, about $0.18/h with translation, per stream; see Soniox pricing)

## Build and run

```bash
git clone https://github.com/alexey-a-abramov/subveil.git
cd subveil
swift test                      # unit + integration tests (local mock Soniox server, no network)
scripts/install_app.sh          # builds, signs, installs ~/Applications/Subveil.app and launches it
```

`install_app.sh` signs with the first *Apple Development* identity in your keychain and falls back to an ad-hoc
signature. A stable signature matters: it lets macOS remember the Keychain, Microphone and System Audio
permissions across rebuilds. Pass an identity explicitly with `scripts/install_app.sh "<identity>"`.

On first launch a short onboarding asks for your Soniox key (verified live), then the microphone and
*System Audio Recording* permissions, each with a live level meter. If system audio stays silent while something
is playing, the panel tells you the permission was probably denied and links to the right System Settings page.

## How to use it

1. Pick **System**, **Mic** or **Both** in the control panel and press ▶.
2. Open the panel (⌄) to choose a microphone, pick specific apps, set translation per source, change the
   display mode, font size and more — all while it runs.
3. Hover the subtitles to move, resize, hide them or open settings. The ✕ on the panel hides it; bring it back
   from the menu bar icon, the Dock icon or `⌥⌘H`.

Tip: with **Both** and built-in speakers, the other side can leak into your microphone. Use headphones, or keep
*voice processing* (echo cancellation) enabled — Subveil also hides near-duplicate phrases automatically.

## Architecture

Swift 6 package, strict concurrency, no third-party dependencies.

| Module | Role |
|---|---|
| `AudioCapture` | Core Audio tap, `AVAudioEngine` mic, real-time-safe ring buffer, 16 kHz resampler, device monitor |
| `SonioxClient` | WebSocket session (reconnect, replay, keepalive, rotation), Codable models, trace log |
| `Transcript` | Token assembler (separate original / translation tracks), store, echo de-duplication, exporters |
| `AppSettings` | Profiles, settings store, Keychain |
| `CaptionsCore` | Engine: sources, sessions, live switching, auto-pause, cost |
| `Overlay`, `ControlHUD` | Subtitle panel and control panel (SwiftUI + AppKit) |
| `Subveil` | App, menu bar, settings, onboarding, hotkeys |

Contributor and agent notes live in [AGENTS.md](AGENTS.md); the roadmap and open questions in [docs/TODO.md](docs/TODO.md).

## License

[MIT](LICENSE) © 2026 Alexey Abramov

## Disclaimer

Subveil is an independent project and is not affiliated with or endorsed by Soniox.
