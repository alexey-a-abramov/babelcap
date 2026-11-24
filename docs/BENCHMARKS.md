# Benchmarks

Measured with `subveil-bench` (release build) on **MacBook Pro, Apple M5 Max, 40-core GPU, 48 GB**, macOS 26.6,
2026-11-24. Clips: ~8–10 s scripted meeting intro read by macOS voices (`Resources/Benchmark`). Local models run on
the GPU, after one untimed warm-up pass. Re-run with:

```bash
swift build -c release --product subveil-bench
$(swift build -c release --show-bin-path)/subveil-bench test ready --clip ru --target en
```

**Speed** = audio duration ÷ processing time, including the translation step when the engine performs one.
Live captions need comfortably more than 1×. **WER** = word error rate against the script (0 % = perfect).

## Fully local pipeline: Whisper large-v3 turbo + TranslateGemma 4B (MLX)

Recognition by Whisper, sentence-by-sentence translation by TranslateGemma 4B (4-bit, GPU), both offline.

| Clip | WER | Speed incl. translation | Translation |
|---|---|---|---|
| Russian → English | 0 % | 13.0× | "Good morning, everyone! Today we'll be discussing the release plan for next week and deciding who will be responsible for testing the new version of the app." |
| Hebrew → English | 0 % | 11.0× | "Good morning everyone. Today we will go over the release plan for next week and decide who will be responsible for checking the new version of the app." |
| English → Russian | 0 % | 14.4× | "Доброе утро, всем! Сегодня мы рассмотрим план выпуска на следующую неделю и определим, кто будет отвечать за тестирование новой версии приложения." |

TranslateGemma 4B alone: ~0.2 s per sentence when warm (~150 tokens/s), ~0.6–0.8 s for the first call including load.

## Russian clip (→ English)

| Engine | WER | Speed | Notes |
|---|---|---|---|
| Soniox stt-rt-v6 (cloud) | 0 % | final text 0.2 s after speech ends | transcript + translation in one stream |
| Whisper large-v3 turbo | 0 % | 16.7× | translation needs Apple Translation (pack RU→EN was not installed) |
| Whisper large-v3 turbo, 632 MB | 0 % | 12.7× | same |
| Whisper large-v3 | 0 % | 3.9× | incl. Whisper's own translation pass |
| Whisper small | 0 % | 6.6× | incl. translation pass |
| Whisper base | 5 % | 19.9× | incl. translation pass |
| Whisper tiny | 10 % | 17.2× | incl. translation pass |
| Apple on-device | — | — | no Russian model on device |
| Distil-Whisper large-v3 turbo | 100 % | — | English-only model |

## English clip

| Engine | WER | Speed |
|---|---|---|
| Soniox stt-rt-v6 (cloud) | 0 % | final text 0.3 s after speech ends |
| Apple on-device | 0 % | 27.5× |
| Whisper tiny / base | 0 % | 48× / 49× |
| Whisper small | 0 % | 24.6× |
| Whisper large-v3 turbo / 632 MB | 0 % | 19.6× / 16.4× |
| Whisper large-v3 | 0 % | 8.9× |

## Hebrew and German (first release run, before warm-up was added — speeds understated)

- **Hebrew:** Soniox 0 %; Whisper large-v3 0 %, turbo 0 %, small 5 %, base 5 %, tiny 47 % (hallucinates).
  Apple has no Hebrew recogniser, and Apple Translation does not support Hebrew.
- **German:** ~8 % WER for every engine (the hyphenated "Release-Plan" counts as an error); turbo 0 %.

## Expected speed on other MacBooks (rough estimate)

Scaled from the measurements above by GPU cores × chip generation (`DeviceEstimate`), tempered for non-linear scaling.
Not measured — orientation only. Russian clip, including the translation step:

| Model | Air M1 (8-core) | Air M2 | Air M4 | Pro M3 Pro | Pro M4 Pro | Pro M4 Max | Pro M5 (10-core) |
|---|---|---|---|---|---|---|---|
| Whisper base | 2.9× | 4.0× | 5.1× | 7.5× | 9.3× | 16.7× | 6.1× |
| Whisper small | 1.0× | 1.3× | 1.7× | 2.5× | 3.1× | 5.5× | 2.0× |
| Whisper large-v3 turbo | 2.5× | 3.4× | 4.3× | 6.3× | 7.8× | 14.0× | 5.1× |
| Whisper large-v3 | 0.6× | 0.8× | 1.0× | 1.5× | 1.8× | 3.2× | 1.2× |

Reading: **large-v3 turbo** is the best local default on any Apple-silicon laptop; **large-v3** needs a Pro/Max chip;
on an M1 Air prefer turbo or base. Apple's own recogniser runs on the Neural Engine and is fast everywhere, but only
for the languages it supports.

## Load time

First load of a Whisper model on the **Neural Engine** compiles it for the Mac and took **315 s** for large-v3 turbo;
on the **GPU** loads take **2–4 s**. Subveil therefore runs Whisper on the GPU.
