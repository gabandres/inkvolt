# Benchmark results (roadmap 3.6)

Written by `dotnet run --project pdf/tools/bench -c Release -- report` on 2026-11-06. The corpus and the measures are described in
[README.md](README.md); run `make`, `run` and `report` again before a release and commit this file.

- **PC:** Microsoft Surface Laptop, 7th Edition, Snapdragon(R) X 12-core X1E80100 @ 3.40 GHz (12 logical processors), 32 GB RAM, Microsoft Windows 10.0.26300 Arm64, .NET 10.0.14.
- **Build:** commit f28ad6f, win-arm64, Release (optimized); each measure is the median of 3 runs, each in a fresh process.
- 2026-11-06 night, branch t3/20b7285b at f28ad6f (a page's check draws the render's picture, two pages ahead, small drawing unsmoothed; the viewer skips the preview of a page its check draws); other Claude sessions open but idle (PC at 29% when it started, a llama-server idle)

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
| First page (read + open + render) | < 1 s | 0.37 s pass | 0.26 s pass | 1.03 s **miss** | 0.79 s pass |
|   of which: read the file / open / render |  | 5 / 42 / 323 ms | 0 / 25 / 235 ms | 0 / 31 / 999 ms | 3 / 289 / 503 ms |
| Scrolling proxy: 20 pages after a cold open, ms/page (slowest) | no page > 200 ms | 12 ms (74) pass | 31 ms (218) **miss**, 1 over | 524 ms (965) **miss**, 15 over | 26 ms (323) **miss**, 1 over |
|   the same pages again, engine still holding them: ms/page |  | 7 ms | 26 ms | 923 ms | 11 ms |
| Find a word across all pages | < 5 s | 3.03 s pass ("lantern": 11,011 hits) | 0.67 s pass ("lantern": 0 hits) | 29.51 s **miss** ("detail": 80 hits) | 1.12 s pass ("lantern": 579 hits) |
|   find workers started, pages they read |  | 8 (4,938 pages) | 6 (450 pages) | 8 (396 pages) | 0 (0 pages) |
| Comment list ready | < 2 s | 0.38 s pass (0 comments) | 0.18 s pass (0 comments) | 0.82 s pass (0 comments) | 1.33 s pass (10,000 comments) |
| Peak working set | < 1.5 GB | 0.35 GB pass | 0.19 GB pass | 0.20 GB pass | 0.30 GB pass |
|   with the find workers' peaks added (an upper bound) | < 1.5 GB | 0.95 GB pass | 0.59 GB pass | 0.64 GB pass | 0.30 GB pass |
| On-screen scroll (app, 4 s at 1,500 px/s): frames per second | 60 fps | 52 fps **miss**, longest gap 58 ms | 51 fps **miss**, longest gap 62 ms | 60 fps pass, longest gap 35 ms | 47 fps **miss**, longest gap 128 ms |
|   frames with a blank page |  | 0 of 210 | 0 of 204 | 165 of 241 | 0 of 187 |
|   pages still blank 200 ms after the scroll stops | none | 0 pass | 0 pass | 1 **miss** | 0 pass |

## What missed

- `text.pdf`: on-screen scroll at 52 fps, 0 page(s) still blank 200 ms after the scroll stopped.
- `scan.pdf`: 1 of the first 20 pages took over 200 ms to render (slowest 218 ms; 31 ms on average).
- `scan.pdf`: on-screen scroll at 51 fps, 0 page(s) still blank 200 ms after the scroll stopped.
- `drawings.pdf`: first page in 1.0 s (reading the file 0.0 s, opening 0.0 s, the render 1.0 s).
- `drawings.pdf`: 15 of the first 20 pages took over 200 ms to render (slowest 965 ms; 524 ms on average).
- `drawings.pdf`: find across 400 pages took 29.5 s.
- `drawings.pdf`: on-screen scroll at 60 fps, 1 page(s) still blank 200 ms after the scroll stopped.
- `comments.pdf`: 1 of the first 20 pages took over 200 ms to render (slowest 323 ms; 26 ms on average).
- `comments.pdf`: on-screen scroll at 47 fps, 0 page(s) still blank 200 ms after the scroll stopped.
