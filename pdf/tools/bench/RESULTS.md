# Benchmark results (roadmap 3.6)

Written by `dotnet run --project pdf/tools/bench -c Release -- report` on 2026-11-22. The corpus and the measures are described in
[README.md](README.md); run `make`, `run` and `report` again before a release and commit this file.

- **PC:** Microsoft Surface Laptop, 7th Edition, Snapdragon(R) X 12-core X1E80100 @ 3.40 GHz (12 logical processors), 32 GB RAM, Microsoft Windows 10.0.26300 Arm64, .NET 10.0.15.
- **Build:** commit 6e0d580d, win-arm64, Release (optimized); each measure is the median of 3 runs, each in a fresh process.
- Release 1.18.0.0; idle PC (no agents running). On-screen scroll: the 1.16.0.0 app, measured the same hour on this PC, gave 49, 30, 57 and 37 fps, so the frame rates below 1.16's run are this PC today, not the app.

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
| First page (read + open + render) | < 1 s | 0.34 s pass | 0.19 s pass | 0.77 s pass | 0.93 s pass |
|   of which: read the file / open / render |  | 3 / 300 / 36 ms | 0 / 26 / 169 ms | 0 / 19 / 755 ms | 6 / 878 / 42 ms |
| Scrolling proxy: 20 pages after a cold open, ms/page (slowest) | no page > 200 ms | 10 ms (47) pass | 31 ms (192) pass | 473 ms (3,401) **miss**, 8 over | 16 ms (54) pass |
|   the same pages again, engine still holding them: ms/page |  | 5 ms | 26 ms | 865 ms | 10 ms |
| Find a word across all pages | < 5 s | 2.58 s pass ("lantern": 11,011 hits) | 0.66 s pass ("lantern": 0 hits) | 32.10 s **miss** ("detail": 80 hits) | 1.06 s pass ("lantern": 579 hits) |
|   find workers started, pages they read |  | 8 (4,885 pages) | 5 (445 pages) | 8 (396 pages) | 0 (0 pages) |
| Comment list ready | < 2 s | 0.44 s pass (0 comments) | 0.17 s pass (0 comments) | 0.63 s pass (0 comments) | 1.02 s pass (10,000 comments) |
| Peak working set | < 1.5 GB | 0.31 GB pass | 0.20 GB pass | 0.20 GB pass | 0.26 GB pass |
|   with the find workers' peaks added (an upper bound) | < 1.5 GB | 0.91 GB pass | 0.54 GB pass | 0.64 GB pass | 0.26 GB pass |
| On-screen scroll (app, 4 s at 1,500 px/s): frames per second | 60 fps | 54 fps **miss**, longest gap 49 ms | 32 fps **miss**, longest gap 47 ms | 52 fps **miss**, longest gap 37 ms | 37 fps **miss**, longest gap 185 ms |
|   frames with a blank page |  | 0 of 217 | 0 of 129 | 0 of 210 | 0 of 148 |
|   pages still blank 200 ms after the scroll stops | none | 0 pass | 0 pass | 0 pass | 0 pass |

## What missed

- `text.pdf`: on-screen scroll at 54 fps, 0 page(s) still blank 200 ms after the scroll stopped.
- `scan.pdf`: on-screen scroll at 32 fps, 0 page(s) still blank 200 ms after the scroll stopped.
- `drawings.pdf`: 8 of the first 20 pages took over 200 ms to render (slowest 3,401 ms; 473 ms on average).
- `drawings.pdf`: find across 400 pages took 32.1 s.
- `drawings.pdf`: on-screen scroll at 52 fps, 0 page(s) still blank 200 ms after the scroll stopped.
- `comments.pdf`: on-screen scroll at 37 fps, 0 page(s) still blank 200 ms after the scroll stopped.
