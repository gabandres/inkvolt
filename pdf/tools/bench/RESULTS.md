# Benchmark results (roadmap 3.6)

Written by `dotnet run --project pdf/tools/bench -c Release -- report` on 2026-11-24. The corpus and the measures are described in
[README.md](README.md); run `make`, `run` and `report` again before a release and commit this file.

- **PC:** Microsoft Surface Laptop, 7th Edition, Snapdragon(R) X 12-core X1E80100 @ 3.40 GHz (12 logical processors), 32 GB RAM, Microsoft Windows 10.0.26300 Arm64, .NET 10.0.15.
- **Build:** commit af218267, win-arm64, Release (optimized); each measure is the median of 3 runs, each in a fresh process.
- Release 1.19.0.0; PC about 11% busy before the run (other sessions open, no builds or tests).

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
| First page (read + open + render) | < 1 s | 0.37 s pass | 0.24 s pass | 0.80 s pass | 1.01 s **miss** |
|   of which: read the file / open / render |  | 5 / 314 / 54 ms | 0 / 30 / 210 ms | 0 / 20 / 784 ms | 3 / 963 / 41 ms |
| Scrolling proxy: 20 pages after a cold open, ms/page (slowest) | no page > 200 ms | 9 ms (23) pass | 35 ms (218) **miss**, 1 over | 412 ms (1,522) **miss**, 12 over | 17 ms (64) pass |
|   the same pages again, engine still holding them: ms/page |  | 5 ms | 29 ms | 982 ms | 10 ms |
| Find a word across all pages | < 5 s | 2.87 s pass ("lantern": 11,011 hits) | 0.70 s pass ("lantern": 0 hits) | 34.83 s **miss** ("detail": 80 hits) | 1.29 s pass ("lantern": 579 hits) |
|   find workers started, pages they read |  | 8 (4,911 pages) | 6 (447 pages) | 8 (396 pages) | 0 (0 pages) |
| Comment list ready | < 2 s | 0.43 s pass (0 comments) | 0.21 s pass (0 comments) | 0.64 s pass (0 comments) | 1.07 s pass (10,000 comments) |
| Peak working set | < 1.5 GB | 0.41 GB pass | 0.20 GB pass | 0.18 GB pass | 0.26 GB pass |
|   with the find workers' peaks added (an upper bound) | < 1.5 GB | 1.01 GB pass | 0.61 GB pass | 0.63 GB pass | 0.26 GB pass |
| On-screen scroll (app, 4 s at 1,500 px/s): frames per second | 60 fps | 54 fps **miss**, longest gap 49 ms | 33 fps **miss**, longest gap 46 ms | 59 fps pass, longest gap 53 ms | 32 fps **miss**, longest gap 175 ms |
|   frames with a blank page |  | 0 of 218 | 0 of 131 | 0 of 238 | 0 of 128 |
|   pages still blank 200 ms after the scroll stops | none | 0 pass | 0 pass | 0 pass | 0 pass |

## What missed

- `text.pdf`: on-screen scroll at 54 fps, 0 page(s) still blank 200 ms after the scroll stopped.
- `scan.pdf`: 1 of the first 20 pages took over 200 ms to render (slowest 218 ms; 35 ms on average).
- `scan.pdf`: on-screen scroll at 33 fps, 0 page(s) still blank 200 ms after the scroll stopped.
- `drawings.pdf`: 12 of the first 20 pages took over 200 ms to render (slowest 1,522 ms; 412 ms on average).
- `drawings.pdf`: find across 400 pages took 34.8 s.
- `comments.pdf`: first page in 1.0 s (reading the file 0.0 s, opening 1.0 s, the render 0.0 s).
- `comments.pdf`: on-screen scroll at 32 fps, 0 page(s) still blank 200 ms after the scroll stopped.
