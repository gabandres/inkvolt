# Benchmark results (roadmap 3.6)

Written by `dotnet run --project pdf/tools/bench -c Release -- report` on 2026-11-22. The corpus and the measures are described in
[README.md](README.md); run `make`, `run` and `report` again before a release and commit this file.

- **PC:** Microsoft Surface Laptop, 7th Edition, Snapdragon(R) X 12-core X1E80100 @ 3.40 GHz (12 logical processors), 32 GB RAM, Microsoft Windows 10.0.26300 Arm64, .NET 10.0.15.
- **Build:** commit af740489, win-arm64, Release (optimized); each measure is the median of 3 runs, each in a fresh process.
- Release 1.17.0.0; two agents' test runs were loading the PC during this run

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
| First page (read + open + render) | < 1 s | 0.51 s pass | 0.58 s pass | 1.08 s **miss** | 0.97 s pass |
|   of which: read the file / open / render |  | 4 / 369 / 132 ms | 0 / 47 / 532 ms | 0 / 18 / 1,064 ms | 3 / 865 / 99 ms |
| Scrolling proxy: 20 pages after a cold open, ms/page (slowest) | no page > 200 ms | 12 ms (56) pass | 51 ms (420) **miss**, 1 over | 2,020 ms (6,669) **miss**, 13 over | 17 ms (48) pass |
|   the same pages again, engine still holding them: ms/page |  | 8 ms | 206 ms | 1,849 ms | 10 ms |
| Find a word across all pages | < 5 s | 3.78 s pass ("lantern": 11,011 hits) | 1.81 s pass ("lantern": 0 hits) | 70.52 s **miss** ("detail": 80 hits) | 1.83 s pass ("lantern": 579 hits) |
|   find workers started, pages they read |  | 8 (4,998 pages) | 8 (492 pages) | 8 (396 pages) | 0 (0 pages) |
| Comment list ready | < 2 s | 2.47 s **miss** (0 comments) | 6.23 s **miss** (0 comments) | 1.47 s pass (0 comments) | 2.63 s **miss** (10,000 comments) |
| Peak working set | < 1.5 GB | 0.39 GB pass | 0.15 GB pass | 0.17 GB pass | 0.25 GB pass |
|   with the find workers' peaks added (an upper bound) | < 1.5 GB | 0.98 GB pass | 0.56 GB pass | 0.61 GB pass | 0.25 GB pass |
| On-screen scroll (app, 4 s at 1,500 px/s): frames per second | 60 fps | 46 fps **miss**, longest gap 94 ms | 62 fps pass, longest gap 34 ms | 57 fps pass, longest gap 68 ms | 37 fps **miss**, longest gap 108 ms |
|   frames with a blank page |  | 0 of 186 | 0 of 247 | 18 of 229 | 0 of 149 |
|   pages still blank 200 ms after the scroll stops | none | 0 pass | 0 pass | 0 pass | 0 pass |

## What missed

- `text.pdf`: the comment list took 2.5 s.
- `text.pdf`: on-screen scroll at 46 fps, 0 page(s) still blank 200 ms after the scroll stopped.
- `scan.pdf`: 1 of the first 20 pages took over 200 ms to render (slowest 420 ms; 51 ms on average).
- `scan.pdf`: the comment list took 6.2 s.
- `drawings.pdf`: first page in 1.1 s (reading the file 0.0 s, opening 0.0 s, the render 1.1 s).
- `drawings.pdf`: 13 of the first 20 pages took over 200 ms to render (slowest 6,669 ms; 2,020 ms on average).
- `drawings.pdf`: find across 400 pages took 70.5 s.
- `comments.pdf`: the comment list took 2.6 s.
- `comments.pdf`: on-screen scroll at 37 fps, 0 page(s) still blank 200 ms after the scroll stopped.
