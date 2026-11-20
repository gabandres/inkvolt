# OCR corpus: photographed pages

Made by `dotnet run --project pdf/tools/ocr-corpus -c Release -- photos` on 2026-11-19, Windows 10.0.26300.0, Arm64, Windows' recognizer. See [README.md](README.md).

| File | What | Words | Stage A (cleaned) | Straightened (trapezoid, bent lines) | ms a page, stage A → straightened |
|---|---|---:|---:|---:|---:|
| `en-trapezoid` | Times-Roman 11 pt, photographed at an angle on a grey desk | 372 | 1.6 % | **0.8 %** | 10587 → 13593 |
| `es-trapezoid` | Helvetica 11 pt, photographed at an angle on a grey desk | 332 | 0.0 % | **0.0 %** | 21027 → 10493 |
| `en-book` | Times-Roman 10 pt, a book's page: lines bent towards the spine | 467 | 100.0 % | **1.7 %** | 22967 → 10801 |
| `es-book` | Times-Roman 11 pt, a book's page: lines bent towards the spine | 370 | 99.5 % | **1.6 %** | 23120 → 12927 |

No worse with the page straightened on any file: **yes**. Stage A reads a bent page's lines crooked or not at all (100%: the bend made the page look upside down, and it was read turned over).
