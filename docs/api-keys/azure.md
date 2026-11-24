# Azure Speech key and region

Azure Speech Translation via Microsoft's Speech SDK: transcript plus translation. $2.50/h; the free F0 tier gives 5 hours a month.
Subveil needs **two things**: a key **and** the resource's region (e.g. `westeurope`).

## 1. Create an Azure account

Sign up at [azure.microsoft.com/free](https://azure.microsoft.com/free/). New customers get a credit for the first 30 days.

## 2. Create a Speech resource

1. Open [Create Speech service](https://portal.azure.com/#create/Microsoft.CognitiveServicesSpeechServices) in the Azure portal.
   (An **Azure AI services / Foundry** multi-service resource works too:
   [create one](https://portal.azure.com/#create/Microsoft.CognitiveServicesAIFoundry).)
2. Fill in:
   - **Subscription** — yours.
   - **Resource group** — create one, e.g. `subveil`.
   - **Region** — one close to you that supports speech translation, e.g. **West Europe** or **East US**
     ([region list](https://learn.microsoft.com/azure/ai-services/speech-service/regions), "Speech translation" tab).
   - **Name** — anything unique.
   - **Pricing tier** — **Free F0** to try (5 h translation/month, 1 stream at a time), **Standard S0** for real use.
3. **Review + create** → **Create** → wait for the deployment → **Go to resource**.

## 3. Copy the key and region

In the resource open **Resource Management → Keys and Endpoint**. Copy **KEY 1** and note **Location/Region**
(the short form, e.g. `westeurope`, `eastus` — lowercase, no spaces).

## 4. Paste them into Subveil

**Models & Providers → Azure Speech Translation → API key**: type the region in **Region**, paste KEY 1 → **Save**.
Then pick Azure as the engine.

## Good to know

- The key only works with **its own region**. A mismatch gives an authentication error.
- **F0 allows one stream at a time** — use System *or* Mic, or "Mix into one stream". S0 allows 100.
- Switching F0 → S0 can take a few hours to apply.

**Official docs:** [Speech translation quickstart](https://learn.microsoft.com/azure/ai-services/speech-service/get-started-speech-translation) ·
[Regions](https://learn.microsoft.com/azure/ai-services/speech-service/regions) ·
[Quotas and limits](https://learn.microsoft.com/azure/ai-services/speech-service/speech-services-quotas-and-limits) ·
[Pricing](https://azure.microsoft.com/pricing/details/cognitive-services/speech-services/)
