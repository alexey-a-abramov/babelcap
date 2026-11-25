# Google Gemini API key (Live Translate)

Gemini Live Translate (`gemini-3.5-live-translate-preview`): source transcript plus translation into one target language. ≈ $2.21/h.

## 1. Sign in

Open [Google AI Studio](https://aistudio.google.com/apikey) with your Google account. AI Studio creates a default
Google Cloud project for you.

## 2. Create a key

1. On the **API keys** page ([link](https://aistudio.google.com/apikey)) click **Create API key**.
2. Copy the key.
3. If AI Studio offers it, use **Add restrictions → Restrict to Gemini API only** — Google rejects unrestricted
   standard keys. Keys created in AI Studio since 28 May 2026 already have the right type.

## 3. Free tier or billing

- The **free tier** works without a card, with per-model rate limits — see [your limits](https://aistudio.google.com/rate-limit).
  Preview models may have tight limits or none on the free tier.
- For more: **Set up billing** on the API keys page, then **Buy credits** on [aistudio.google.com/billing](https://aistudio.google.com/billing)
  (prepay $5–5,000, credits expire after 12 months). At $0 balance every key on that billing account gets `402`.

## 4. Paste it into Babelcap

**Models & Providers → Google Gemini Live Translate → API key** → paste → **Save**. Then pick it as the engine.

## Good to know

- Gemini translates into **one** target language; two-way translation is not available with this engine.
- Google closes live sessions every ~10–15 minutes; Babelcap reconnects on its own.

**Official docs:** [API keys](https://ai.google.dev/gemini-api/docs/api-key) · [Billing](https://ai.google.dev/gemini-api/docs/billing) ·
[Rate limits](https://ai.google.dev/gemini-api/docs/rate-limits) · [Live API](https://ai.google.dev/gemini-api/docs/live) ·
[Pricing](https://ai.google.dev/gemini-api/docs/pricing)
