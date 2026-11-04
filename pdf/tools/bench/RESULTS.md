# Benchmark results (roadmap 3.6)

Written by `dotnet run --project pdf/tools/bench -c Release -- report` on 2026-11-04. The corpus and the measures are described in
[README.md](README.md); run `make`, `run` and `report` again before a release and commit this file.

- **PC:** Microsoft Surface Laptop, 7th Edition, Snapdragon(R) X 12-core X1E80100 @ 3.40 GHz (12 logical processors), 32 GB RAM, Microsoft Windows 10.0.26300 Arm64, .NET 10.0.14.
- **Build:** commit 6bb2a25, win-arm64, Release (optimized); each measure is the median of 3 runs, each in a fresh process.
- Before the next Inkvolt PDF release (Spanish interface), on mains, not idle: other sessions were running (CPU 40 to 75 % before the run). On-screen frame rates are the PC's load as much as the app's.

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
| First page (read + open + render) | < 1 s | 0.10 s pass | 0.08 s pass | 0.58 s pass | 0.34 s pass |
|   of which: read the file / open / render |  | 8 / 52 / 44 ms | 0 / 27 / 51 ms | 0 / 18 / 566 ms | 3 / 303 / 38 ms |
| Scrolling proxy: 20 pages after a cold open, ms/page (slowest) | no page > 200 ms | 6 ms (16) pass | 28 ms (32) pass | 992 ms (1,394) **miss**, 20 over | 10 ms (22) pass |
|   the same pages again, engine still holding them: ms/page |  | 5 ms | 4 ms | 806 ms | 7 ms |
| Find a word across all pages | < 5 s | 3.57 s pass ("lantern": 11,011 hits) | 0.41 s pass ("lantern": 0 hits) | 39.54 s **miss** ("detail": 80 hits) | 0.68 s pass ("lantern": 579 hits) |
|   find workers started, pages they read |  | 8 (4,861 pages) | 0 (0 pages) | 8 (396 pages) | 0 (0 pages) |
| Comment list ready | < 2 s | 0.46 s pass (0 comments) | 0.22 s pass (0 comments) | 0.71 s pass (0 comments) | 0.78 s pass (10,000 comments) |
| Peak working set | < 1.5 GB | 0.26 GB pass | 0.18 GB pass | 0.17 GB pass | 0.17 GB pass |
|   with the find workers' peaks added (an upper bound) | < 1.5 GB | 0.85 GB pass | 0.18 GB pass | 0.60 GB pass | 0.17 GB pass |
| On-screen scroll (app, 4 s at 1,500 px/s): frames per second | 60 fps | 56 fps pass, longest gap 47 ms | 58 fps pass, longest gap 53 ms | 58 fps pass, longest gap 54 ms | 36 fps **miss**, longest gap 145 ms |
|   frames with a blank page |  | 0 of 224 | 0 of 233 | 196 of 234 | 0 of 146 |
|   pages still blank 200 ms after the scroll stops | none | 0 pass | 0 pass | 1 **miss** | 0 pass |

## What missed

- `drawings.pdf`: 20 of the first 20 pages took over 200 ms to render (slowest 1,394 ms; 992 ms on average).
- `drawings.pdf`: find across 400 pages took 39.5 s.
- `drawings.pdf`: on-screen scroll at 58 fps, 1 page(s) still blank 200 ms after the scroll stopped.
- `comments.pdf`: on-screen scroll at 36 fps, 0 page(s) still blank 200 ms after the scroll stopped.
