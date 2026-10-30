# OCR corpus: word error rate

Made by `dotnet run --project pdf/tools/ocr-corpus -c Release -- run` on 2026-10-30, Windows 10.0.26300.0, Arm64. See [README.md](README.md) for the corpus and the measure.

| File | Words | Today | Today, its language chosen | Stage A (cleaned) | ms a page, today → stage A |
|---|---:|---:|---:|---:|---:|
| `en-skew3-light` | 767 | 1.8 % (en-US) | 1.8 % (en-US) | **1.3 %** | 497 → 896 |
| `en-skew6-noisy` | 807 | 16.9 % (en-US) | 16.9 % (en-US) | **12.9 %** | 1558 → 1320 |
| `en-skew10-shaded` | 911 | 5.4 % (en-US) | 5.4 % (en-US) | **3.8 %** | 1790 → 1157 |
| `es-skew4-noisy` | 688 | 44.9 % (en-US) | 12.8 % (es-MX) | **8.0 %** | 1514 → 1264 |
| `es-skew8-shaded` | 738 | 41.3 % (en-US) | 5.1 % (es-MX) | **4.3 %** | 1975 → 1124 |
| `en-turned` | 767 | 99.9 % (en-US) | 99.9 % (en-US) | **3.7 %** | 1414 → 1209 |

Lower than today's on every file: **yes**.

| File | What | SHA-256 |
|---|---|---|
| `en-skew3-light` | English, Times 11 pt, skew 3-4°, noise σ 8, 150 specks a page, paper 10 levels darker on one side | `73a9e0af326e8172…` |
| `en-skew6-noisy` | English, Helvetica 10 pt, skew 5-7°, noise σ 26, 1500 specks a page | `bb64c7cb90f5b49a…` |
| `en-skew10-shaded` | English, Times 10 pt, skew 8.5-10°, noise σ 14, 400 specks a page, paper 60 levels darker on one side | `b4e358a9e6cf423c…` |
| `es-skew4-noisy` | Spanish, Helvetica 11 pt, skew 3.5-5°, noise σ 24, 1200 specks a page | `285fde830bb24b87…` |
| `es-skew8-shaded` | Spanish, Times 11 pt, skew 7-9°, noise σ 14, 400 specks a page, paper 50 levels darker on one side | `93d4060e88535a1a…` |
| `en-turned` | English, Times 11 pt, skew 3-5°, noise σ 12, 300 specks a page, paper 20 levels darker on one side, pages turned 180° and 90° | `ef461cae573f26ed…` |
