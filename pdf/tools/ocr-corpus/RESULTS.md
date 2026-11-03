# OCR corpus: word error rate

Made by `dotnet run --project pdf/tools/ocr-corpus -c Release -- run` on 2026-11-03, Windows 10.0.26300.0, Arm64. See [README.md](README.md) for the corpus and the measure.

Re-reading missed lines (`MissedLines`, 2026-11-03): Windows' recognizer skips no line on the six scan files (nor on the 36 pages of `probe --count 18`), so their numbers stay; looking for unread ink costs 10-25 ms a page, and the ms columns move with the PC's load (other jobs ran). `skipped-lines` is a typeset page it skips two lines of, cleaned or not; read again, 4 of their 6 words come back in place (it reads "1111" in no way, even alone).

| File | Words | Today | Today, its language chosen | Cleaned | Stage A (cleaned, missed lines re-read) | ms a page, today → cleaned → stage A |
|---|---:|---:|---:|---:|---:|---:|
| `en-skew3-light` | 767 | 1.8 % (en-US) | 1.8 % (en-US) | 1.3 % | **1.3 %** | 515 → 846 → 1139 |
| `en-skew6-noisy` | 807 | 16.9 % (en-US) | 16.9 % (en-US) | 12.9 % | **12.9 %** | 1472 → 1208 → 1269 |
| `en-skew10-shaded` | 911 | 5.4 % (en-US) | 5.4 % (en-US) | 3.8 % | **3.8 %** | 1683 → 1205 → 1172 |
| `es-skew4-noisy` | 688 | 44.9 % (en-US) | 12.8 % (es-MX) | 8.0 % | **8.0 %** | 1410 → 1214 → 1234 |
| `es-skew8-shaded` | 738 | 41.3 % (en-US) | 5.1 % (es-MX) | 4.3 % | **4.3 %** | 1760 → 1163 → 1164 |
| `en-turned` | 767 | 99.9 % (en-US) | 99.9 % (en-US) | 3.7 % | **3.7 %** | 1445 → 1205 → 1198 |
| `skipped-lines` | 23 | 34.8 % (en-US) | 34.8 % (en-US) | 39.1 % | **21.7 %** | 445 → 560 → 687 |

Lower than today's on every file: **yes**. Re-reading missed lines no worse on every file: **yes**.

| File | What | SHA-256 |
|---|---|---|
| `en-skew3-light` | English, Times 11 pt, skew 3-4°, noise σ 8, 150 specks a page, paper 10 levels darker on one side | `73a9e0af326e8172…` |
| `en-skew6-noisy` | English, Helvetica 10 pt, skew 5-7°, noise σ 26, 1500 specks a page | `bb64c7cb90f5b49a…` |
| `en-skew10-shaded` | English, Times 10 pt, skew 8.5-10°, noise σ 14, 400 specks a page, paper 60 levels darker on one side | `b4e358a9e6cf423c…` |
| `es-skew4-noisy` | Spanish, Helvetica 11 pt, skew 3.5-5°, noise σ 24, 1200 specks a page | `285fde830bb24b87…` |
| `es-skew8-shaded` | Spanish, Times 11 pt, skew 7-9°, noise σ 14, 400 specks a page, paper 50 levels darker on one side | `93d4060e88535a1a…` |
| `en-turned` | English, Times 11 pt, skew 3-5°, noise σ 12, 300 specks a page, paper 20 levels darker on one side, pages turned 180° and 90° | `ef461cae573f26ed…` |
| `skipped-lines` | Helvetica 14 pt, typeset, no damage: two lines Windows' recognizer skips | `6bf2904b8e88f4d0…` |
