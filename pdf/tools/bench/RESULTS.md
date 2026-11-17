# Benchmark results (roadmap 3.6)

Written by `dotnet run --project pdf/tools/bench -c Release -- report` on 2026-11-17. The corpus and the measures are described in
[README.md](README.md); run `make`, `run` and `report` again before a release and commit this file.

- **PC:** Microsoft Surface Laptop, 7th Edition, Snapdragon(R) X 12-core X1E80100 @ 3.40 GHz (12 logical processors), 32 GB RAM, Microsoft Windows 10.0.26300 Arm64, .NET 10.0.15.
- **Build:** commit 1b96ca76, win-arm64, Release (optimized); each measure is the median of 3 runs, each in a fresh process.
- before 1.15.0.0 (1b96ca76), on .NET SDK 11; PC otherwise idle

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
| First page (read + open + render) | < 1 s | 0.44 s pass | 0.23 s pass | 0.82 s pass | 1.08 s **miss** |
|   of which: read the file / open / render |  | 6 / 315 / 116 ms | 0 / 29 / 202 ms | 0 / 19 / 806 ms | 3 / 695 / 380 ms |
| Scrolling proxy: 20 pages after a cold open, ms/page (slowest) | no page > 200 ms | 11 ms (78) pass | 30 ms (123) pass | 599 ms (1,000) **miss**, 16 over | 27 ms (334) **miss**, 1 over |
|   the same pages again, engine still holding them: ms/page |  | 7 ms | 26 ms | 904 ms | 12 ms |
| Find a word across all pages | < 5 s | 2.85 s pass ("lantern": 11,011 hits) | 0.65 s pass ("lantern": 0 hits) | 31.82 s **miss** ("detail": 80 hits) | 1.28 s pass ("lantern": 579 hits) |
|   find workers started, pages they read |  | 8 (4,952 pages) | 6 (449 pages) | 8 (396 pages) | 8 (208 pages) |
| Comment list ready | < 2 s | 0.43 s pass (0 comments) | 0.18 s pass (0 comments) | 0.62 s pass (0 comments) | 0.80 s pass (10,000 comments) |
| Peak working set | < 1.5 GB | 0.37 GB pass | 0.19 GB pass | 0.18 GB pass | 0.26 GB pass |
|   with the find workers' peaks added (an upper bound) | < 1.5 GB | 0.97 GB pass | 0.59 GB pass | 0.62 GB pass | 0.26 GB pass |
| On-screen scroll (app, 4 s at 1,500 px/s): frames per second | 60 fps | 55 fps pass, longest gap 59 ms | 48 fps **miss**, longest gap 62 ms | 60 fps pass, longest gap 29 ms | 40 fps **miss**, longest gap 203 ms |
|   frames with a blank page |  | 0 of 221 | 0 of 194 | 197 of 242 | 6 of 160 |
|   pages still blank 200 ms after the scroll stops | none | 0 pass | 0 pass | 1 **miss** | 0 pass |

## What missed

- `scan.pdf`: on-screen scroll at 48 fps, 0 page(s) still blank 200 ms after the scroll stopped.
- `drawings.pdf`: 16 of the first 20 pages took over 200 ms to render (slowest 1,000 ms; 599 ms on average).
- `drawings.pdf`: find across 400 pages took 31.8 s.
- `drawings.pdf`: on-screen scroll at 60 fps, 1 page(s) still blank 200 ms after the scroll stopped.
- `comments.pdf`: first page in 1.1 s (reading the file 0.0 s, opening 0.7 s, the render 0.4 s).
- `comments.pdf`: 1 of the first 20 pages took over 200 ms to render (slowest 334 ms; 27 ms on average).
- `comments.pdf`: on-screen scroll at 40 fps, 0 page(s) still blank 200 ms after the scroll stopped.
