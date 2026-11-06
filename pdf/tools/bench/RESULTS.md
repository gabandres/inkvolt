# Benchmark results (roadmap 3.6)

Written by `dotnet run --project pdf/tools/bench -c Release -- report` on 2026-11-06. The corpus and the measures are described in
[README.md](README.md); run `make`, `run` and `report` again before a release and commit this file.

- **PC:** Microsoft Surface Laptop, 7th Edition, Snapdragon(R) X 12-core X1E80100 @ 3.40 GHz (12 logical processors), 32 GB RAM, Microsoft Windows 10.0.26300 Arm64, .NET 10.0.14.
- **Build:** commit 42ccf89, win-arm64, Release (optimized); each measure is the median of 3 runs, each in a fresh process.
- 2026-11-06, branch t3/20b7285b at 42ccf89 (the review's fixes: verdict before picture, picture within its own 1.5 s, check smoothed again, pages ahead at their own scale; a check process started with the app); straight after master c932ac4 back to back; other sessions idle (PC at 2 to 10% before each)

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
| First page (read + open + render) | < 1 s | 0.24 s pass | 0.23 s pass | 0.82 s pass | 0.67 s pass |
|   of which: read the file / open / render |  | 4 / 38 / 193 ms | 0 / 27 / 199 ms | 0 / 19 / 800 ms | 3 / 287 / 381 ms |
| Scrolling proxy: 20 pages after a cold open, ms/page (slowest) | no page > 200 ms | 11 ms (75) pass | 29 ms (121) pass | 685 ms (1,431) **miss**, 16 over | 27 ms (331) **miss**, 1 over |
|   the same pages again, engine still holding them: ms/page |  | 7 ms | 26 ms | 919 ms | 11 ms |
| Find a word across all pages | < 5 s | 2.82 s pass ("lantern": 11,011 hits) | 0.71 s pass ("lantern": 0 hits) | 30.72 s **miss** ("detail": 80 hits) | 1.19 s pass ("lantern": 579 hits) |
|   find workers started, pages they read |  | 8 (4,940 pages) | 6 (448 pages) | 8 (396 pages) | 0 (0 pages) |
| Comment list ready | < 2 s | 0.35 s pass (0 comments) | 0.18 s pass (0 comments) | 0.67 s pass (0 comments) | 1.39 s pass (10,000 comments) |
| Peak working set | < 1.5 GB | 0.38 GB pass | 0.20 GB pass | 0.18 GB pass | 0.31 GB pass |
|   with the find workers' peaks added (an upper bound) | < 1.5 GB | 0.98 GB pass | 0.61 GB pass | 0.62 GB pass | 0.31 GB pass |
| On-screen scroll (app, 4 s at 1,500 px/s): frames per second | 60 fps | 55 fps pass, longest gap 67 ms | 57 fps pass, longest gap 49 ms | 60 fps pass, longest gap 30 ms | 46 fps **miss**, longest gap 88 ms |
|   frames with a blank page |  | 0 of 222 | 0 of 230 | 174 of 240 | 0 of 184 |
|   pages still blank 200 ms after the scroll stops | none | 0 pass | 0 pass | 1 **miss** | 0 pass |

## What missed

- `drawings.pdf`: 16 of the first 20 pages took over 200 ms to render (slowest 1,431 ms; 685 ms on average).
- `drawings.pdf`: find across 400 pages took 30.7 s.
- `drawings.pdf`: on-screen scroll at 60 fps, 1 page(s) still blank 200 ms after the scroll stopped.
- `comments.pdf`: 1 of the first 20 pages took over 200 ms to render (slowest 331 ms; 27 ms on average).
- `comments.pdf`: on-screen scroll at 46 fps, 0 page(s) still blank 200 ms after the scroll stopped.
