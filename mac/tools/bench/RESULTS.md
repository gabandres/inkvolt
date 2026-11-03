# Speed on huge files: Inkvolt PDF for Mac

Made by `mac/tools/bench` (README.md) on 2026-11-02: **MacBookAir10,1, Apple M1, 8 cores, 16 GB, macOS 27.2.0**. The medians of 3 runs, each in a fresh process, over PdfCore in a release build.

- Measured on the M1 MacBook Air (16 GB, 4 performance and 4 efficiency cores), the Mac the M6 Mac mini replaces: run it again there and commit what it says.

## The corpus

The same pages as Windows' (`pdf/tools/bench`: the same generator, seeds and words); the bytes differ (Apple's deflate and ImageIO's JPEG encoder), so the SHA-256s do too.

| File | What | Size | SHA-256 |
|---|---|---|---|
| `text.pdf` | 5,000-page text document: real paragraphs in Times, Helvetica, Courier and Helvetica-Bold (standard fonts, Flate content) | 8.0 MB | `979950c983a3b594…` |
| `scan.pdf` | 500-page scan: 300 dpi grayscale JPEG pages (2550 × 3300 px) with paper noise, text-like lines and specks | 445.9 MB | `84425c54cc146558…` |
| `drawings.pdf` | 400-sheet drawing set (ARCH D, 36 × 24 in): hatching, polylines and circles, 72,000 paths per sheet, a title block | 611.3 MB | `02c11787cc37f663…` |
| `comments.pdf` | 250-page text document with 10,000 comments: notes, highlights, underlines, strike-outs, boxes, circles, ink, text boxes, with popups, and replies | 6.5 MB | `b665b5d6ec925c9a…` |

## Measures against the targets

| Measure | Target | `text.pdf` | `scan.pdf` | `drawings.pdf` | `comments.pdf` |
|---|---|---|---|---|---|
| Pages |  | 5,000 | 500 | 400 | 250 |
| First page (read + open + render) | < 1 s | 0.04 s pass | 0.12 s pass | 0.71 s pass | 0.17 s pass |
|   of which: read the file / open / render |  | 1 / 32 / 8 ms | 54 / 35 / 26 ms | 74 / 48 / 588 ms | 0 / 154 / 13 ms |
| Scrolling proxy: 20 pages after a cold open, ms/page (slowest) | no page > 200 ms | 1 ms (7) pass | 26 ms (26) pass | 584 ms (587) **miss**, 20 over | 6 ms (13) pass |
|   the same pages again, engine still holding them: ms/page |  | 1 ms | 12 ms | 515 ms | 5 ms |
| Find a word across all pages | < 5 s | 0.55 s pass ("lantern": 11,011 hits) | 0.00 s pass ("lantern": 0 hits) | 6.91 s **miss** ("detail": 80 hits) | 0.07 s pass ("lantern": 579 hits) |
|   threads reading text |  | 7 | 7 | 7 | 7 |
|   a second search ("harbor"), from what the first remembered |  | 0.47 s | 0.00 s | 0.00 s | 0.00 s |
| Comment list ready | < 2 s | 0.01 s pass (0 comments) | 0.02 s pass (0 comments) | 0.02 s pass (0 comments) | 0.21 s pass (10,000 comments) |
| Peak resident memory | < 1.5 GB | 0.15 GB pass | 0.96 GB pass | 1.31 GB pass | 0.14 GB pass |

## Before and after E16 (the same Air, the same corpus)

| | Before | After | What changed |
|---|---|---|---|
| Find, `text.pdf` | 2.33 s | 0.55 s | `PdfEngine.findAll`: pages read on 7 threads, each with its own MuPDF instance; text remembered for the next search |
| Find, `drawings.pdf` | 33.5 s | 6.91 s | the same |
| Find, `comments.pdf` | 0.27 s | 0.07 s | the same |
| A second search, `text.pdf` | 2.33 s (read again) | 0.47 s | the remembered strings checked on the same threads (on one, they took 1.3 s) |
| Peak memory, `drawings.pdf` | 2.56 GB | 1.31 GB | one copy of the file's bytes for all of an engine's instances (`SharedBytes`, MuPDF reading in place); a closed engine lets go of them; the file read straight into one array (`PdfEngine.readFile`) |
| Peak memory, `scan.pdf` | 4.48 GB | 0.96 GB | the same (the "before" scan was 1.09 GB, made at ImageIO quality 0.75; the corpus now uses 0.51, Windows' page size) |

`scale` (each thread an engine of its own, so not the app's memory): `text.pdf` 2.37 s on 1 thread, 1.22 s on 2, 0.70 s on 4,
0.58 s on 7, 0.55 s on 8; `drawings.pdf` 33.5 s on 1, 9.6 s on 4, 8.1 s on 7. MuPDF instances don't wait on each other on
the Mac (Windows' MuPDFCore made them, hence its find workers), so Find stays in one process.

## What missed


- `drawings.pdf`: 20 of the first 20 pages took over 200 ms to render (slowest 587 ms; 584 ms on average).
- `drawings.pdf`: find across 400 pages took 6.91 s.

The on-screen scroll (Windows' `scrollbench`) isn't measured on the Mac yet: see README.md.
