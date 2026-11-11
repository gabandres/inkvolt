# Benchmark results (roadmap 3.6)

Written by `dotnet run --project pdf/tools/bench -c Release -- report` on 2026-11-10. The corpus and the measures are described in
[README.md](README.md); run `make`, `run` and `report` again before a release and commit this file.

- **PC:** Microsoft Surface Laptop, 7th Edition, Snapdragon(R) X 12-core X1E80100 @ 3.40 GHz (12 logical processors), 32 GB RAM, Microsoft Windows 10.0.26300 Arm64, .NET 10.0.15.
- **Build:** commit b19c39f1, win-arm64, Release (optimized); each measure is the median of 3 runs, each in a fresh process.
- before Inkvolt PDF 1.13.0.0, 2026-11-10; PC shared with other sessions

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
| First page (read + open + render) | < 1 s | 0.45 s pass | 0.28 s pass | 0.87 s pass | 1.09 s **miss** |
|   of which: read the file / open / render |  | 5 / 323 / 122 ms | 0 / 32 / 246 ms | 0 / 26 / 847 ms | 4 / 705 / 380 ms |
| Scrolling proxy: 20 pages after a cold open, ms/page (slowest) | no page > 200 ms | 13 ms (84) pass | 37 ms (152) pass | 688 ms (1,627) **miss**, 17 over | 28 ms (333) **miss**, 1 over |
|   the same pages again, engine still holding them: ms/page |  | 7 ms | 31 ms | 938 ms | 11 ms |
| Find a word across all pages | < 5 s | 3.27 s pass ("lantern": 11,011 hits) | 1.00 s pass ("lantern": 0 hits) | 31.63 s **miss** ("detail": 80 hits) | 1.55 s pass ("lantern": 579 hits) |
|   find workers started, pages they read |  | 8 (4,973 pages) | 6 (452 pages) | 8 (396 pages) | 0 (0 pages) |
| Comment list ready | < 2 s | 0.46 s pass (0 comments) | 0.39 s pass (0 comments) | 0.64 s pass (0 comments) | 0.88 s pass (10,000 comments) |
| Peak working set | < 1.5 GB | 0.37 GB pass | 0.20 GB pass | 0.19 GB pass | 0.25 GB pass |
|   with the find workers' peaks added (an upper bound) | < 1.5 GB | 0.97 GB pass | 0.53 GB pass | 0.63 GB pass | 0.25 GB pass |
| On-screen scroll (app, 4 s at 1,500 px/s): frames per second | 60 fps | 56 fps pass, longest gap 59 ms | 58 fps pass, longest gap 112 ms | 59 fps pass, longest gap 69 ms | 40 fps **miss**, longest gap 146 ms |
|   frames with a blank page |  | 0 of 225 | 0 of 231 | 224 of 238 | 0 of 160 |
|   pages still blank 200 ms after the scroll stops | none | 0 pass | 0 pass | 2 **miss** | 0 pass |

## What missed

- `drawings.pdf`: 17 of the first 20 pages took over 200 ms to render (slowest 1,627 ms; 688 ms on average).
- `drawings.pdf`: find across 400 pages took 31.6 s.
- `drawings.pdf`: on-screen scroll at 59 fps, 2 page(s) still blank 200 ms after the scroll stopped.
- `comments.pdf`: first page in 1.1 s (reading the file 0.0 s, opening 0.7 s, the render 0.4 s).
- `comments.pdf`: 1 of the first 20 pages took over 200 ms to render (slowest 333 ms; 28 ms on average).
- `comments.pdf`: on-screen scroll at 40 fps, 0 page(s) still blank 200 ms after the scroll stopped.
