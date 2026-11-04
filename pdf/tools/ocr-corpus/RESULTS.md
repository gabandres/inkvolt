# OCR corpus: word error rate

Made by `dotnet run --project pdf/tools/ocr-corpus -c Release -- run` on 2026-11-04, Windows 10.0.26300.0, Arm64. See [README.md](README.md) for the corpus and the measure.

Words inside lines, and 1111 (2026-11-04): a run of four 1s or more (`1111`), which Windows' recognizer never reads and for which it leaves out the whole line, is read three strokes at a time; a word left out inside a line that was read is read again on its own (`MissedLines.FindInLines`). `skipped-lines` 21.7 % → **8.7 %** (the three 1111 now read; a comma lost twice is what is left). The six scans are unchanged: the words they lack inside lines are two words read as one (journeyxletter), not words left out. `probe --count 18` (36 pages, 14,108 words): 752 → 747 edits, 7 words found inside lines, none worse.

| File | Words | Today | Today, its language chosen | Cleaned | Stage A (cleaned, missed lines re-read) | ms a page, today → cleaned → stage A |
|---|---:|---:|---:|---:|---:|---:|
| `en-skew3-light` | 767 | 1.8 % (en-US) | 1.8 % (en-US) | 1.3 % | **1.3 %** | 502 → 826 → 1071 |
| `en-skew6-noisy` | 807 | 16.9 % (en-US) | 16.9 % (en-US) | 12.9 % | **12.9 %** | 1493 → 1333 → 1379 |
| `en-skew10-shaded` | 911 | 5.4 % (en-US) | 5.4 % (en-US) | 3.8 % | **3.8 %** | 1690 → 1231 → 1251 |
| `es-skew4-noisy` | 688 | 44.9 % (en-US) | 12.8 % (es-MX) | 8.0 % | **8.0 %** | 1398 → 1276 → 1280 |
| `es-skew8-shaded` | 738 | 41.3 % (en-US) | 5.1 % (es-MX) | 4.3 % | **4.3 %** | 1793 → 1157 → 1341 |
| `en-turned` | 767 | 99.9 % (en-US) | 99.9 % (en-US) | 3.7 % | **3.7 %** | 1492 → 1247 → 1212 |
| `skipped-lines` | 23 | 34.8 % (en-US) | 34.8 % (en-US) | 39.1 % | **8.7 %** | 419 → 558 → 618 |
| `digit-lines` | 11 | 9.1 % (en-US) | 9.1 % (en-US) | 27.3 % | **27.3 %** | 274 → 818 → 866 |

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
| `digit-lines` | Helvetica 14 pt, typeset, no damage: three lines of numbers, which read plausibly turned over | `30c8994cfac9bdee…` |
