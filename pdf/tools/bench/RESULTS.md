# Benchmark results (roadmap 3.6)

Written by `dotnet run --project pdf/tools/bench -c Release -- report` on 2026-11-02. The corpus and the measures are described in
[README.md](README.md); run `make`, `run` and `report` again before a release and commit this file.

- **PC:** Microsoft Surface Laptop, 7th Edition, Snapdragon(R) X 12-core X1E80100 @ 3.40 GHz (12 logical processors), 32 GB RAM, Microsoft Windows 10.0.26300 Arm64, .NET 10.0.14.
- **Build:** commit 4e958ce, win-arm64, Release (optimized); each measure is the median of 3 runs, each in a fresh process.
- Before the 1.6.0 release, on mains, not idle: other sessions and their programs were running (CPU about 37 % right after). The viewer's scrolling code didn't change since 1.5.0, so the lower on-screen numbers are the PC's load, not measured as such.

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
| First page (read + open + render) | < 1 s | 0.08 s pass | 0.07 s pass | 0.51 s pass | 0.32 s pass |
|   of which: read the file / open / render |  | 4 / 38 / 35 ms | 0 / 23 / 51 ms | 0 / 15 / 497 ms | 3 / 275 / 38 ms |
| Scrolling proxy: 20 pages after a cold open, ms/page (slowest) | no page > 200 ms | 6 ms (16) pass | 26 ms (33) pass | 773 ms (933) **miss**, 20 over | 10 ms (21) pass |
|   the same pages again, engine still holding them: ms/page |  | 4 ms | 4 ms | 580 ms | 7 ms |
| Find a word across all pages | < 5 s | 2.50 s pass ("lantern": 11,011 hits) | 0.54 s pass ("lantern": 0 hits) | 29.87 s **miss** ("detail": 80 hits) | 0.76 s pass ("lantern": 579 hits) |
|   find workers started, pages they read |  | 8 (4,887 pages) | 0 (0 pages) | 8 (396 pages) | 0 (0 pages) |
| Comment list ready | < 2 s | 0.31 s pass (0 comments) | 0.16 s pass (0 comments) | 0.64 s pass (0 comments) | 0.79 s pass (10,000 comments) |
| Peak working set | < 1.5 GB | 0.28 GB pass | 0.18 GB pass | 0.17 GB pass | 0.17 GB pass |
|   with the find workers' peaks added (an upper bound) | < 1.5 GB | 0.87 GB pass | 0.18 GB pass | 0.60 GB pass | 0.17 GB pass |
| On-screen scroll (app, 4 s at 1,500 px/s): frames per second | 60 fps | 55 fps **miss**, longest gap 62 ms | 51 fps **miss**, longest gap 64 ms | 59 fps pass, longest gap 68 ms | 40 fps **miss**, longest gap 221 ms |
|   frames with a blank page |  | 0 of 219 | 0 of 205 | 224 of 238 | 0 of 161 |
|   pages still blank 200 ms after the scroll stops | none | 0 pass | 0 pass | 1 **miss** | 0 pass |

## What missed

- `text.pdf`: on-screen scroll at 55 fps, 0 page(s) still blank 200 ms after the scroll stopped.
- `scan.pdf`: on-screen scroll at 51 fps, 0 page(s) still blank 200 ms after the scroll stopped.
- `drawings.pdf`: 20 of the first 20 pages took over 200 ms to render (slowest 933 ms; 773 ms on average).
- `drawings.pdf`: find across 400 pages took 29.9 s.
- `drawings.pdf`: on-screen scroll at 59 fps, 1 page(s) still blank 200 ms after the scroll stopped.
- `comments.pdf`: on-screen scroll at 40 fps, 0 page(s) still blank 200 ms after the scroll stopped.
