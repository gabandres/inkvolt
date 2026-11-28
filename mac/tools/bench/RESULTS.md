# Speed on huge files: Inkvolt PDF for Mac

Made by `mac/tools/bench` (README.md) on 2026-11-28: **Mac17,3, Apple M5, 10 cores, 16 GB, macOS 27.2.1**. The medians of 3 runs, each in a fresh process, over PdfCore in a release build.

- release 1.14.0 prep, 2026-11-28; build Mac idle but for this run

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
| First page (read + open + render) | < 1 s | 0.03 s pass | 0.08 s pass | 0.22 s pass | 0.11 s pass |
|   of which: read the file / open / render |  | 0 / 24 / 5 ms | 37 / 24 / 15 ms | 48 / 33 / 140 ms | 0 / 101 / 9 ms |
| Scrolling proxy: 20 pages after a cold open, ms/page (slowest) | no page > 200 ms | 1 ms (5) pass | 14 ms (15) pass | 143 ms (151) pass | 4 ms (8) pass |
|   the same pages again, engine still holding them: ms/page |  | 0 ms | 5 ms | 92 ms | 3 ms |
| Find a word across all pages | < 5 s | 0.32 s pass ("lantern": 11,011 hits) | 0.00 s pass ("lantern": 0 hits) | 4.29 s pass ("detail": 80 hits) | 0.04 s pass ("lantern": 579 hits) |
|   threads reading text |  | 8 | 8 | 8 | 8 |
|   a second search ("harbor"), from what the first remembered |  | 0.29 s | 0.00 s | 0.00 s | 0.00 s |
| Comment list ready | < 2 s | 0.01 s pass (0 comments) | 0.01 s pass (0 comments) | 0.01 s pass (0 comments) | 0.14 s pass (10,000 comments) |
| Peak resident memory | < 1.5 GB | 0.16 GB pass | 0.96 GB pass | 1.32 GB pass | 0.15 GB pass |

## What missed

Nothing.

The on-screen scroll (Windows' `scrollbench`) isn't measured on the Mac yet: see README.md.
