# Soniox API key

Soniox is Subveil's default engine: real-time transcription and translation in one stream. ≈ $0.12/h, ≈ $0.18/h with translation.

## 1. Create an account

Sign up at [console.soniox.com/signup](https://console.soniox.com/signup).

## 2. Create a key

1. In the [Soniox Console](https://console.soniox.com) open your project (new accounts get **My First Project**).
2. Click **API Keys** ([direct link](https://console.soniox.com/org/projects/api/keys/)) → create a key.
3. Copy it. Soniox keys look like `snx_proj_…` and are long (≈ 150 characters).

## 3. Add money

1. Go to **Organization → Billing** ([link](https://console.soniox.com/org/billing/overview/)) and add funds.
2. Optional but recommended: set a monthly cap in **Organization → Limits** ([link](https://console.soniox.com/org/limits/)).

## 4. Paste it into Subveil

**Settings → Account** or **Models & Providers → Soniox → API key** → paste → **Verify & save**.
Subveil checks the key with Soniox before saving it.

## Good to know

- Keys belong to a **project**. Deleting the project disables all its keys.
- Create the project in the **default (US) region**. A project's region can't be changed later, and an EU-region key
  only works against `api.eu.soniox.com`, which Subveil does not call yet.
- Billing is by session time. Auto-pause on silence (Settings → Session) keeps it down.
- Limits take a short while to apply; usage over the limit inside that window is still billed.

**Official docs:** [Get started](https://docs.soniox.com/stt/get-started) · [Console guide](https://docs.soniox.com/console) ·
[Real-time API](https://docs.soniox.com/stt/rt/real-time-transcription) · [Pricing](https://soniox.com/pricing)
