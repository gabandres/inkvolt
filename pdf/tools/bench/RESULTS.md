# Benchmark results (roadmap 3.6)

Written by `dotnet run --project pdf/tools/bench -c Release -- report` on 2026-11-06. The corpus and the measures are described in
[README.md](README.md); run `make`, `run` and `report` again before a release and commit this file.

- **PC:** Microsoft Surface Laptop, 7th Edition, Snapdragon(R) X 12-core X1E80100 @ 3.40 GHz (12 logical processors), 32 GB RAM, Microsoft Windows 10.0.26300 Arm64, .NET 10.0.14.
- **Build:** commit aa8f28da, win-arm64, Release (optimized); each measure is the median of 3 runs, each in a fresh process.
- 2026-11-06, branch t3/7adaf919 at aa8f28da (Inkvolt PDF 1.9.0.0 release; the hostile-input review's Follow fix); other sessions active (PC at 20 to 60% before, a local model idle)

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
| First page (read + open + render) | < 1 s | 0.24 s pass | 0.23 s pass | 0.94 s pass | 0.68 s pass |
|   of which: read the file / open / render |  | 4 / 41 / 191 ms | 0 / 27 / 203 ms | 0 / 19 / 922 ms | 3 / 298 / 380 ms |
| Scrolling proxy: 20 pages after a cold open, ms/page (slowest) | no page > 200 ms | 12 ms (79) pass | 35 ms (221) **miss**, 1 over | 605 ms (1,584) **miss**, 15 over | 28 ms (333) **miss**, 1 over |
|   the same pages again, engine still holding them: ms/page |  | 7 ms | 27 ms | 998 ms | 11 ms |
| Find a word across all pages | < 5 s | 3.04 s pass ("lantern": 11,011 hits) | 0.69 s pass ("lantern": 0 hits) | 32.43 s **miss** ("detail": 80 hits) | 1.18 s pass ("lantern": 579 hits) |
|   find workers started, pages they read |  | 8 (4,885 pages) | 6 (453 pages) | 8 (396 pages) | 0 (0 pages) |
| Comment list ready | < 2 s | 0.44 s pass (0 comments) | 0.17 s pass (0 comments) | 0.62 s pass (0 comments) | 1.30 s pass (10,000 comments) |
| Peak working set | < 1.5 GB | 0.29 GB pass | 0.19 GB pass | 0.18 GB pass | 0.28 GB pass |
|   with the find workers' peaks added (an upper bound) | < 1.5 GB | 0.89 GB pass | 0.59 GB pass | 0.62 GB pass | 0.28 GB pass |
| On-screen scroll (app, 4 s at 1,500 px/s): frames per second | 60 fps | 59 fps pass, longest gap 35 ms | 52 fps **miss**, longest gap 56 ms | 59 fps pass, longest gap 44 ms | 43 fps **miss**, longest gap 148 ms |
|   frames with a blank page |  | 0 of 237 | 0 of 207 | 198 of 237 | 0 of 172 |
|   pages still blank 200 ms after the scroll stops | none | 0 pass | 0 pass | 2 **miss** | 0 pass |

## What missed

- `scan.pdf`: 1 of the first 20 pages took over 200 ms to render (slowest 221 ms; 35 ms on average).
- `scan.pdf`: on-screen scroll at 52 fps, 0 page(s) still blank 200 ms after the scroll stopped.
- `drawings.pdf`: 15 of the first 20 pages took over 200 ms to render (slowest 1,584 ms; 605 ms on average).
- `drawings.pdf`: find across 400 pages took 32.4 s.
- `drawings.pdf`: on-screen scroll at 59 fps, 2 page(s) still blank 200 ms after the scroll stopped.
- `comments.pdf`: 1 of the first 20 pages took over 200 ms to render (slowest 333 ms; 28 ms on average).
- `comments.pdf`: on-screen scroll at 43 fps, 0 page(s) still blank 200 ms after the scroll stopped.
