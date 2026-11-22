# Speed on huge files: Inkvolt PDF for Mac

Made by `mac/tools/bench` (README.md) before 1.12.0, 2026-11-11, on master `3ce8aca5`: **MacBookAir10,1, Apple M1, 8
cores, 16 GB, macOS 27.2.0**, at a load of 1.5 to 5.6. The medians of 3 runs, each in a fresh process, over PdfCore in a
release build. The next `run` overwrites this file: keep the notes below by hand.

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
| First page (read + open + render) | < 1 s | 42 ms pass | 118 ms pass | 326 ms pass | 182 ms pass |
| Scrolling proxy: 20 pages after a cold open, ms/page (slowest) | no page > 200 ms | 1 (7) pass | 26 (26) pass | 202 (209) **miss** | 6 (14) pass |
| Find a word across all pages | < 5 s | 0.57 s pass | 0.01 s pass | 7.97 s **miss** | 0.07 s pass |
| Comment list ready | < 2 s | 0.01 s pass | 0.02 s pass | 0.02 s pass | 0.22 s pass (10,000) |
| Peak resident memory | < 1.5 GB | 156 MB pass | 983 MB pass | 1.35 GB pass | 147 MB pass |

## What missed

- `drawings.pdf`: 15 of the first 20 pages took over 200 ms to render (202 ms on average). Windows misses it too.
- `drawings.pdf`: Find across 400 pages took 7.97 s: MuPDF's content lexer and inflate are 80% of it.

The on-screen scroll (Windows' `scrollbench`) isn't measured on the Mac yet: see README.md.

## Notes

- The Air's load moves these numbers a lot (Find on the drawing set took 15.4 s at a load of 7 to 22 with the same
  code): compare like with like, interleaving the base build and the new one with `one` when a change might matter.
- Why Find stays in one process: `scale` showed MuPDF instances don't wait on each other on the Mac (`text.pdf` 2.37 s on
  1 thread, 0.70 s on 4, 0.55 s on 8; `drawings.pdf` 33.5 s on 1, 8.1 s on 7), unlike Windows' MuPDFCore, hence its
  find workers.
- Drawing in bands (`bands`; PLAN.md, "Speed on huge files: drawing in bands") took the drawing set's first render from
  617 to 257 ms and its scroll from 707 to 261 ms a page, Find unchanged.
