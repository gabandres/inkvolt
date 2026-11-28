# Benchmark results (roadmap 3.6)

Written by `dotnet run --project pdf/tools/bench -c Release -- report` on 2026-11-28. The corpus and the measures are described in
[README.md](README.md); run `make`, `run` and `report` again before a release and commit this file.

- **PC:** Microsoft Surface Laptop, 7th Edition, Snapdragon(R) X 12-core X1E80100 @ 3.40 GHz (12 logical processors), 32 GB RAM, Microsoft Windows 10.0.26340 Arm64, .NET 10.0.15.
- **Build:** commit 5d88c32f, win-arm64, Release (optimized); each measure is the median of 3 runs, each in a fresh process.
- release 1.20.0 prep, 2026-11-28; other agents idle

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
| First page (read + open + render) | < 1 s | 0.67 s pass | 0.35 s pass | 1.85 s **miss** | 1.50 s **miss** |
|   of which: read the file / open / render |  | 7 / 587 / 72 ms | 0 / 50 / 298 ms | 0 / 34 / 1,815 ms | 5 / 1,424 / 69 ms |
| Scrolling proxy: 20 pages after a cold open, ms/page (slowest) | no page > 200 ms | 19 ms (105) pass | 67 ms (352) **miss**, 1 over | 1,035 ms (3,544) **miss**, 12 over | 27 ms (95) pass |
|   the same pages again, engine still holding them: ms/page |  | 11 ms | 53 ms | 790 ms | 17 ms |
| Find a word across all pages | < 5 s | 6.58 s **miss** ("lantern": 11,011 hits) | 1.16 s pass ("lantern": 0 hits) | 39.62 s **miss** ("detail": 80 hits) | 2.16 s pass ("lantern": 579 hits) |
|   find workers started, pages they read |  | 8 (4,944 pages) | 7 (460 pages) | 8 (396 pages) | 7 (179 pages) |
| Comment list ready | < 2 s | 0.18 s pass (0 comments) | 0.30 s pass (0 comments) | 0.65 s pass (0 comments) | 0.91 s pass (10,000 comments) |
| Peak working set | < 1.5 GB | 0.39 GB pass | 0.20 GB pass | 0.19 GB pass | 0.27 GB pass |
|   with the find workers' peaks added (an upper bound) | < 1.5 GB | 0.97 GB pass | 0.67 GB pass | 0.63 GB pass | 0.84 GB pass |
| On-screen scroll (app, 4 s at 1,500 px/s): frames per second | 60 fps | 53 fps **miss**, longest gap 49 ms | 58 fps pass, longest gap 42 ms | 55 fps pass, longest gap 48 ms | 33 fps **miss**, longest gap 164 ms |
|   frames with a blank page |  | 0 of 211 | 0 of 234 | 0 of 221 | 6 of 132 |
|   pages still blank 200 ms after the scroll stops | none | 0 pass | 0 pass | 0 pass | 0 pass |

## What missed

- `text.pdf`: find across 5,000 pages took 6.6 s.
- `text.pdf`: on-screen scroll at 53 fps, 0 page(s) still blank 200 ms after the scroll stopped.
- `scan.pdf`: 1 of the first 20 pages took over 200 ms to render (slowest 352 ms; 67 ms on average).
- `drawings.pdf`: first page in 1.8 s (reading the file 0.0 s, opening 0.0 s, the render 1.8 s).
- `drawings.pdf`: 12 of the first 20 pages took over 200 ms to render (slowest 3,544 ms; 1,035 ms on average).
- `drawings.pdf`: find across 400 pages took 39.6 s.
- `comments.pdf`: first page in 1.5 s (reading the file 0.0 s, opening 1.4 s, the render 0.1 s).
- `comments.pdf`: on-screen scroll at 33 fps, 0 page(s) still blank 200 ms after the scroll stopped.
