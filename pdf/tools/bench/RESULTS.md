# Benchmark results (roadmap 3.6)

Written by `dotnet run --project pdf/tools/bench -c Release -- report` on 2026-11-21. The corpus and the measures are described in
[README.md](README.md); run `make`, `run` and `report` again before a release and commit this file.

- **PC:** Microsoft Surface Laptop, 7th Edition, Snapdragon(R) X 12-core X1E80100 @ 3.40 GHz (12 logical processors), 32 GB RAM, Microsoft Windows 10.0.26300 Arm64, .NET 10.0.15.
- **Build:** commit 15ef1db7, win-arm64, Release (optimized); each measure is the median of 3 runs, each in a fresh process.

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
| First page (read + open + render) | < 1 s | 0.34 s pass | 0.20 s pass | 0.80 s pass | 0.88 s pass |
|   of which: read the file / open / render |  | 4 / 298 / 39 ms | 0 / 30 / 169 ms | 0 / 26 / 771 ms | 3 / 837 / 42 ms |
| Scrolling proxy: 20 pages after a cold open, ms/page (slowest) | no page > 200 ms | 11 ms (53) pass | 34 ms (232) **miss**, 1 over | 518 ms (3,412) **miss**, 8 over | 16 ms (30) pass |
|   the same pages again, engine still holding them: ms/page |  | 5 ms | 26 ms | 890 ms | 9 ms |
| Find a word across all pages | < 5 s | 2.60 s pass ("lantern": 11,011 hits) | 0.69 s pass ("lantern": 0 hits) | 34.23 s **miss** ("detail": 80 hits) | 1.04 s pass ("lantern": 579 hits) |
|   find workers started, pages they read |  | 8 (4,899 pages) | 6 (444 pages) | 8 (396 pages) | 0 (0 pages) |
| Comment list ready | < 2 s | 0.44 s pass (0 comments) | 0.18 s pass (0 comments) | 0.60 s pass (0 comments) | 0.97 s pass (10,000 comments) |
| Peak working set | < 1.5 GB | 0.37 GB pass | 0.21 GB pass | 0.18 GB pass | 0.27 GB pass |
|   with the find workers' peaks added (an upper bound) | < 1.5 GB | 0.97 GB pass | 0.62 GB pass | 0.62 GB pass | 0.27 GB pass |
| On-screen scroll (app, 4 s at 1,500 px/s): frames per second | 60 fps | 70 fps pass, longest gap 47 ms | 61 fps pass, longest gap 57 ms | 74 fps pass, longest gap 66 ms | 60 fps pass, longest gap 92 ms |
|   frames with a blank page |  | 2 of 282 | 14 of 245 | 297 of 297 | 7 of 240 |
|   pages still blank 200 ms after the scroll stops | none | 0 pass | 0 pass | 6 **miss** | 0 pass |

## What missed

- `scan.pdf`: 1 of the first 20 pages took over 200 ms to render (slowest 232 ms; 34 ms on average).
- `drawings.pdf`: 8 of the first 20 pages took over 200 ms to render (slowest 3,412 ms; 518 ms on average).
- `drawings.pdf`: find across 400 pages took 34.2 s.
- `drawings.pdf`: on-screen scroll at 74 fps, 6 page(s) still blank 200 ms after the scroll stopped.
