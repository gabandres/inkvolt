# Benchmark results (roadmap 3.6)

Written by `dotnet run --project pdf/tools/bench -c Release -- report` on 2026-11-07. The corpus and the measures are described in
[README.md](README.md); run `make`, `run` and `report` again before a release and commit this file.

- **PC:** Microsoft Surface Laptop, 7th Edition, Snapdragon(R) X 12-core X1E80100 @ 3.40 GHz (12 logical processors), 32 GB RAM, Microsoft Windows 10.0.26300 Arm64, .NET 10.0.14.
- **Build:** commit 2aa0e077, win-arm64, Release (optimized); each measure is the median of 3 runs, each in a fresh process.
- before Inkvolt PDF 1.11.0.0, 2026-11-07; PC about 60% busy with other sessions

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
| First page (read + open + render) | < 1 s | 0.39 s pass | 0.27 s pass | 0.89 s pass | 1.20 s **miss** |
|   of which: read the file / open / render |  | 4 / 271 / 117 ms | 0 / 37 / 236 ms | 0 / 20 / 871 ms | 3 / 825 / 368 ms |
| Scrolling proxy: 20 pages after a cold open, ms/page (slowest) | no page > 200 ms | 11 ms (76) pass | 35 ms (157) pass | 821 ms (1,657) **miss**, 17 over | 27 ms (322) **miss**, 1 over |
|   the same pages again, engine still holding them: ms/page |  | 6 ms | 30 ms | 1,113 ms | 11 ms |
| Find a word across all pages | < 5 s | 3.12 s pass ("lantern": 11,011 hits) | 0.73 s pass ("lantern": 0 hits) | 36.39 s **miss** ("detail": 80 hits) | 1.36 s pass ("lantern": 579 hits) |
|   find workers started, pages they read |  | 8 (4,932 pages) | 6 (451 pages) | 8 (396 pages) | 8 (210 pages) |
| Comment list ready | < 2 s | 0.35 s pass (0 comments) | 0.20 s pass (0 comments) | 0.68 s pass (0 comments) | 0.83 s pass (10,000 comments) |
| Peak working set | < 1.5 GB | 0.35 GB pass | 0.24 GB pass | 0.18 GB pass | 0.26 GB pass |
|   with the find workers' peaks added (an upper bound) | < 1.5 GB | 0.95 GB pass | 0.64 GB pass | 0.62 GB pass | 0.26 GB pass |
| On-screen scroll (app, 4 s at 1,500 px/s): frames per second | 60 fps | 52 fps **miss**, longest gap 55 ms | 57 fps pass, longest gap 43 ms | 59 fps pass, longest gap 67 ms | 45 fps **miss**, longest gap 127 ms |
|   frames with a blank page |  | 0 of 207 | 0 of 229 | 48 of 236 | 0 of 180 |
|   pages still blank 200 ms after the scroll stops | none | 0 pass | 0 pass | 0 pass | 0 pass |

## What missed

- `text.pdf`: on-screen scroll at 52 fps, 0 page(s) still blank 200 ms after the scroll stopped.
- `drawings.pdf`: 17 of the first 20 pages took over 200 ms to render (slowest 1,657 ms; 821 ms on average).
- `drawings.pdf`: find across 400 pages took 36.4 s.
- `comments.pdf`: first page in 1.2 s (reading the file 0.0 s, opening 0.8 s, the render 0.4 s).
- `comments.pdf`: 1 of the first 20 pages took over 200 ms to render (slowest 322 ms; 27 ms on average).
- `comments.pdf`: on-screen scroll at 45 fps, 0 page(s) still blank 200 ms after the scroll stopped.
