# Benchmark results (roadmap 3.6)

Written by `dotnet run --project pdf/tools/bench -c Release -- report` on 2026-11-07. The corpus and the measures are described in
[README.md](README.md); run `make`, `run` and `report` again before a release and commit this file.

- **PC:** Microsoft Surface Laptop, 7th Edition, Snapdragon(R) X 12-core X1E80100 @ 3.40 GHz (12 logical processors), 32 GB RAM, Microsoft Windows 10.0.26300 Arm64, .NET 10.0.14.
- **Build:** commit 60697e05, win-arm64, Release (optimized); each measure is the median of 3 runs, each in a fresh process.
- before Inkvolt PDF 1.10.0.0, 2026-11-07; PC about 35% busy with other sessions

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
| First page (read + open + render) | < 1 s | 0.24 s pass | 0.22 s pass | 0.82 s pass | 0.66 s pass |
|   of which: read the file / open / render |  | 4 / 38 / 195 ms | 0 / 27 / 198 ms | 0 / 21 / 798 ms | 6 / 287 / 370 ms |
| Scrolling proxy: 20 pages after a cold open, ms/page (slowest) | no page > 200 ms | 12 ms (78) pass | 34 ms (207) **miss**, 1 over | 643 ms (1,361) **miss**, 17 over | 27 ms (332) **miss**, 1 over |
|   the same pages again, engine still holding them: ms/page |  | 6 ms | 25 ms | 947 ms | 11 ms |
| Find a word across all pages | < 5 s | 2.81 s pass ("lantern": 11,011 hits) | 0.75 s pass ("lantern": 0 hits) | 31.54 s **miss** ("detail": 80 hits) | 1.20 s pass ("lantern": 579 hits) |
|   find workers started, pages they read |  | 8 (4,934 pages) | 6 (448 pages) | 8 (396 pages) | 0 (0 pages) |
| Comment list ready | < 2 s | 0.38 s pass (0 comments) | 0.18 s pass (0 comments) | 0.61 s pass (0 comments) | 1.38 s pass (10,000 comments) |
| Peak working set | < 1.5 GB | 0.38 GB pass | 0.21 GB pass | 0.21 GB pass | 0.30 GB pass |
|   with the find workers' peaks added (an upper bound) | < 1.5 GB | 0.98 GB pass | 0.62 GB pass | 0.66 GB pass | 0.30 GB pass |
| On-screen scroll (app, 4 s at 1,500 px/s): frames per second | 60 fps | 60 fps pass, longest gap 37 ms | 60 fps pass, longest gap 44 ms | 58 fps pass, longest gap 94 ms | 47 fps **miss**, longest gap 89 ms |
|   frames with a blank page |  | 0 of 239 | 0 of 241 | 111 of 232 | 0 of 189 |
|   pages still blank 200 ms after the scroll stops | none | 0 pass | 0 pass | 2 **miss** | 0 pass |

## What missed

- `scan.pdf`: 1 of the first 20 pages took over 200 ms to render (slowest 207 ms; 34 ms on average).
- `drawings.pdf`: 17 of the first 20 pages took over 200 ms to render (slowest 1,361 ms; 643 ms on average).
- `drawings.pdf`: find across 400 pages took 31.5 s.
- `drawings.pdf`: on-screen scroll at 58 fps, 2 page(s) still blank 200 ms after the scroll stopped.
- `comments.pdf`: 1 of the first 20 pages took over 200 ms to render (slowest 332 ms; 27 ms on average).
- `comments.pdf`: on-screen scroll at 47 fps, 0 page(s) still blank 200 ms after the scroll stopped.
