# OCR corpus: Inkvolt Print's scan cleanup

Made by `dotnet run --project pdf/tools/ocr-corpus -c Release -- cleanup` on 2026-10-31, Windows 10.0.26300.0, Arm64. See [README.md](README.md).

OCR languages installed on this PC: en-US, es-MX.

| File | Words | Damage | Today (straightened) | Cleaned | Filters' ms a page |
|---|---:|---|---:|---:|---:|
| `en-skewed-lid` | 741 | SkewedOnLid | 5.9 % | **5.7 %** | 1617 |
| `en-grey` | 746 | GreyPaper | 20.2 % | **19.7 %** | 814 |
| `en-halftoned` | 791 | Halftoned | 10.0 % | **4.6 %** | 1425 |
| `en-faded` | 736 | Faded | 4.9 % | **3.4 %** | 1022 |
| `es-grey` | 660 | GreyPaper | 20.6 % | **18.8 %** | 827 |
| `es-halftoned` | 662 | Halftoned | 8.0 % | **2.3 %** | 1156 |
| `es-faded` | 701 | Faded | 2.7 % | **3.0 %** | 935 |
| `ru-grey-skewed` | 611 | GreyPaper | not run | not run: ru-RU isn't installed | |
| `ru-halftoned` | 605 | Halftoned | not run | not run: ru-RU isn't installed | |
| `ja-grey-skewed` | 60 | GreyPaper | not run | not run: ja-JP isn't installed | |
| `ja-faded` | 60 | Faded | not run | not run: ja-JP isn't installed | |

Lower than today's on every file measured: **no** (7 of 11 files measured).
