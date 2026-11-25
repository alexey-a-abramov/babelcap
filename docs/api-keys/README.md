# Getting API keys

Babelcap is BYOK: you bring your own key and pay the provider directly. Babelcap keeps the key in the macOS Keychain
and sends it only to that provider. Offline engines (Whisper, Apple, TranslateGemma) need no key at all.

Pick a provider, follow its page, then paste the key in Babelcap: **menu bar icon → Models & Providers → the provider → API key → Save**.

| Provider | Translation | Price (approx.) | Free to try | Guide |
|---|---|---|---|---|
| Soniox *(recommended)* | Built in, one or two way | $0.12/h, ≈ $0.18/h with translation | — | [soniox.md](soniox.md) |
| Gladia | Built in (add-on) | from €0.16/h + €0.05/h translation | €50 credit | [gladia.md](gladia.md) |
| Speechmatics | Built in (add-on) | $0.30–0.80/h + $0.65/h translation | $100 credit | [speechmatics.md](speechmatics.md) |
| OpenAI realtime-translate | Built in (speech to speech) | ≈ $2.04/h | — | [openai.md](openai.md) |
| Google Gemini Live Translate | Built in, one way | ≈ $2.21/h | Free tier | [gemini.md](gemini.md) |
| ElevenLabs Scribe | On your Mac (local translator) | $0.22/h | 2.5 h realtime/month | [elevenlabs.md](elevenlabs.md) |
| Azure Speech Translation | Built in | $2.50/h | 5 h/month (F0) | [azure.md](azure.md) |
| AssemblyAI *(adapter planned)* | — | $0.30–0.45/h | $50 credit | [assemblyai.md](assemblyai.md) |
| Deepgram *(adapter planned)* | — | see pricing | $200 credit | [deepgram.md](deepgram.md) |

Prices and free credits are what the providers published on 24 Nov 2026; check their pricing pages before you rely on them.

## General rules

- **A key is a password.** Don't paste it into chats, screenshots or shared files. If it leaks, delete it in the provider's console and create a new one.
- **Many consoles show the full key only once.** Copy it straight into Babelcap.
- **Set a spending limit** where the provider offers one. Babelcap pauses on silence to save money, but a forgotten session still costs.
- **Wrong key?** Babelcap shows `401` / "Incorrect API key". **Out of money?** It shows `402`.
