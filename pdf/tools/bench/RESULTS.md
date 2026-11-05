# Benchmark results (roadmap 3.6)

Written by `dotnet run --project pdf/tools/bench -c Release -- report` on 2026-11-05. The corpus and the measures are described in
[README.md](README.md); run `make`, `run` and `report` again before a release and commit this file.

- **PC:** Microsoft Surface Laptop, 7th Edition, Snapdragon(R) X 12-core X1E80100 @ 3.40 GHz (12 logical processors), 32 GB RAM, Microsoft Windows 10.0.26300 Arm64, .NET 10.0.14.
- **Build:** commit 267578d, win-arm64, Release (optimized); each measure is the median of 3 runs, each in a fresh process.
- 2026-11-05 night, before 1.8.0.0; no agents running; page checks (MuPDF time limit) merged

## The corpus

| File | What | Size | SHA-256 |
|---|---|---|---|
| `text.pdf` | 5,000-page text document: real paragraphs in Times, Helvetica, Courier and Helvetica-Bold (standard fonts, Flate content) | 8.0 MB | `1d6aa048fa3b78d0…` |
| `scan.pdf` | 500-page scan: 300 dpi grayscale JPEG pages (2550 × 3300 px) with paper noise, text-like lines and specks | 428.2 MB | `50bfafecc72d6468…` |
| `drawings.pdf` | 400-sheet drawing set (ARCH D, 36 × 24 in): hatching, polylines and circles, 72,000 paths per sheet, a title block | 1,017.0 MB | `f5067a3ce4224aef…` |
| `comments.pdf` | 250-page text document with 10,000 comments: notes, highlights, underlines, strike-outs, boxes, circles, ink, text boxes, with popups, and replies | 6.5 MB | `efdfd602a82dbe54…` |

## Measures against the targets

| Measure | Target | `text.pdf` | `scan.pdf` | `drawings.pdf` | `comments.pdf` |
|---|---|---|---|---|---|
| Pages |  | 5,000 | 500 | 400 | 250 |
| First page (read + open + render) | < 1 s | 0.26 s pass | 0.22 s pass | 1.01 s **miss** | 0.75 s pass |
|   of which: read the file / open / render |  | 4 / 40 / 219 ms | 0 / 25 / 197 ms | 0 / 21 / 991 ms | 3 / 282 / 468 ms |
| Scrolling proxy: 20 pages after a cold open, ms/page (slowest) | no page > 200 ms | 11 ms (83) pass | 26 ms (71) pass | 969 ms (1,110) **miss**, 20 over | 27 ms (320) **miss**, 1 over |
|   the same pages again, engine still holding them: ms/page |  | 4 ms | 4 ms | 742 ms | 7 ms |
| Find a word across all pages | < 5 s | 2.92 s pass ("lantern": 11,011 hits) | 0.67 s pass ("lantern": 0 hits) | 38.38 s **miss** ("detail": 80 hits) | 1.17 s pass ("lantern": 579 hits) |
|   find workers started, pages they read |  | 8 (4,919 pages) | 6 (447 pages) | 8 (396 pages) | 0 (0 pages) |
| Comment list ready | < 2 s | 0.37 s pass (0 comments) | 0.19 s pass (0 comments) | 0.75 s pass (0 comments) | 1.42 s pass (10,000 comments) |
| Peak working set | < 1.5 GB | 0.34 GB pass | 0.16 GB pass | 0.17 GB pass | 0.17 GB pass |
|   with the find workers' peaks added (an upper bound) | < 1.5 GB | 0.94 GB pass | 0.56 GB pass | 0.61 GB pass | 0.17 GB pass |
| On-screen scroll (app, 4 s at 1,500 px/s): frames per second | 60 fps | 58 fps pass, longest gap 45 ms | 57 fps pass, longest gap 57 ms | 60 fps pass, longest gap 36 ms | 43 fps **miss**, longest gap 83 ms |
|   frames with a blank page |  | 0 of 233 | 0 of 227 | 214 of 238 | 0 of 171 |
|   pages still blank 200 ms after the scroll stops | none | 0 pass | 0 pass | 1 **miss** | 0 pass |

## What missed

- `drawings.pdf`: first page in 1.0 s (reading the file 0.0 s, opening 0.0 s, the render 1.0 s).
- `drawings.pdf`: 20 of the first 20 pages took over 200 ms to render (slowest 1,110 ms; 969 ms on average).
- `drawings.pdf`: find across 400 pages took 38.4 s.
- `drawings.pdf`: on-screen scroll at 60 fps, 1 page(s) still blank 200 ms after the scroll stopped.
- `comments.pdf`: 1 of the first 20 pages took over 200 ms to render (slowest 320 ms; 27 ms on average).
- `comments.pdf`: on-screen scroll at 43 fps, 0 page(s) still blank 200 ms after the scroll stopped.
