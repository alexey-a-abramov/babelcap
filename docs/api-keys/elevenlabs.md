# ElevenLabs API key (Scribe)

ElevenLabs Scribe v3 Live: low-latency transcription in the cloud, $0.22/h. Scribe does not translate —
Subveil translates each line on your Mac with the translator you pick (TranslateGemma or Apple Translation).

## 1. Create an account

Sign up at [elevenlabs.io/app/sign-up](https://elevenlabs.io/app/sign-up). The **Free** plan includes 2.5 hours of
realtime transcription per month.

## 2. Create a key

1. Open **API keys** in the dashboard ([link](https://elevenlabs.io/app/settings/api-keys)) → **Create API key**.
2. Name it `Subveil`. If you restrict the key's permissions, keep Speech to Text allowed. Leave the IP allowlist empty unless you know your IP is fixed.
3. Copy the key.

## 3. Paying (when the free hours run out)

Pick an API plan at [elevenlabs.io/pricing/api](https://elevenlabs.io/pricing/api) (subscribe in [your subscription page](https://elevenlabs.io/app/subscription/api)).
Self-serve plans can also buy pay-as-you-go credits.

## 4. Paste it into Subveil

**Models & Providers → ElevenLabs Scribe v3 Live → API key** → paste → **Save**. Then pick it as the engine and
choose a translator (download TranslateGemma 4B in the same window if you haven't).

## Good to know

- Realtime is billed for **every second of audio sent, silence included**. Keep auto-pause on.
- A key can have its own credit quota — handy as a spending cap.

**Official docs:** [Authentication](https://elevenlabs.io/docs/api-reference/authentication) ·
[Speech to Text](https://elevenlabs.io/docs/capabilities/speech-to-text) · [Pricing](https://elevenlabs.io/pricing/api)
