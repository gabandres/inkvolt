# Speed on huge files: Inkvolt PDF for Mac

Made by `mac/tools/bench` (README.md) on 2026-11-07: **MacBookAir10,1, Apple M1, 8 cores, 16 GB, macOS 27.2.0**. The medians of 3 runs, each in a fresh process, over PdfCore in a release build.

- Measured on the M1 MacBook Air (16 GB, 4 performance and 4 efficiency cores) while another session's builds kept the
  load between 2 and 8 (1.85 when it started): Find on the drawing set took 9.8 s here against 6.9 s on the quiet run of
  2026-11-02, with its code unchanged. The interleaved runs below compare like with like. Run it again on the M6 Mac mini.

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
| First page (read + open + render) | < 1 s | 0.04 s pass | 0.14 s pass | 0.72 s pass | 0.18 s pass |
|   of which: read the file / open / render |  | 1 / 34 / 8 ms | 64 / 52 / 27 ms | 327 / 154 / 239 ms | 0 / 164 / 14 ms |
| Scrolling proxy: 20 pages after a cold open, ms/page (slowest) | no page > 200 ms | 1 ms (7) pass | 26 ms (27) pass | 223 ms (251) **miss**, 20 over | 6 ms (13) pass |
|   the same pages again, engine still holding them: ms/page |  | 1 ms | 12 ms | 147 ms | 5 ms |
| Find a word across all pages | < 5 s | 0.58 s pass ("lantern": 11,011 hits) | 0.01 s pass ("lantern": 0 hits) | 9.84 s **miss** ("detail": 80 hits) | 0.08 s pass ("lantern": 579 hits) |
|   threads reading text |  | 7 | 7 | 7 | 7 |
|   a second search ("harbor"), from what the first remembered |  | 0.50 s | 0.00 s | 0.00 s | 0.00 s |
| Comment list ready | < 2 s | 0.01 s pass (0 comments) | 0.02 s pass (0 comments) | 0.06 s pass (0 comments) | 0.23 s pass (10,000 comments) |
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

## Before and after drawing in bands (2026-11-07, the same Air, the same corpus)

The base commit's bench and this branch's, run one after the other on each file three times (`one`, a fresh process each),
the medians; the load was 2 to 14 from another session's builds (the first pair, at 2 to 3.6, in brackets).

| `drawings.pdf` | Before | After | What changed |
|---|---|---|---|
| First page: render | 617 ms (616) | 257 ms (257) | the sheet's display list drawn in 8 bands, one a core (`inkv_draw_bands`) |
| Scrolling proxy, ms/page | 707 (607) | 261 (237) | the same |
| Slowest of the 20 | 900 ms (649) | 312 ms (291) | the same |
| The same pages again, ms/page | 587 (555) | 166 (155) | the same: the list is kept, only the drawing is left |
| Find | 10.2 s (9.0) | 9.9 s (9.8) | unchanged: MuPDF's content lexer (`fz_strtof`, `lex_number`) and inflate are 80% of it |
| Peak memory | 1.34 GB | 1.34 GB | |

`text.pdf`, `scan.pdf` and `comments.pdf` are unchanged (their pages have pictures or few paths, so they are drawn on one
thread as before). `bands` (8 bands against 1, 4, 16; unfair locks against pthread mutexes and a spin lock) is in PLAN.md.

After the review's fixes (each band's own stop flag, a drawing out of time drawn again on one thread, Type3 glyphs with
pictures on one thread): the branch before them (300a6337) and after, interleaved, 3 runs each (`one`), started at a load
of 1.82 (5.90 at the end, the bench's own threads). Each run was a little slower than the one before on the fanless Air
(scroll 197, 201, 213 ms before; 199, 207, 219 after), so the 1 to 3% between each pair is within that drift.

| `drawings.pdf` | Before the fixes | After | |
|---|---|---|---|
| First page: render | 208 ms | 214 ms | |
| Scrolling proxy, ms/page | 201 | 207 | |
| Slowest of the 20 | 208 ms | 216 ms | |
| The same pages again, ms/page | 133 | 137 | |
| Find | 7.9 s | 8.5 s | unchanged code (the text instances draw nothing) |
| Peak memory | 1.31 GB | 1.31 GB | |

## Before 1.11.0 (2026-11-10, the same Air, the same corpus)

`run`, 3 runs each, at a load of 7 to 22 (other projects' emulators and simulators had kept it at 300 to 700 for the hour
before; at a load of 8 to 20 an earlier run was slower still):

| Measure | `text.pdf` | `scan.pdf` | `drawings.pdf` | `comments.pdf` |
|---|---|---|---|---|
| First page | 73 ms | 153 ms | 918 ms | 300 ms |
| Scrolling proxy, ms/page (slowest) | 3 (13) | 35 (40) | 350 (432) | 11 (20) |
| Find | 1.06 s | 0.01 s | 15.4 s | 0.12 s |
| Comment list | 0.02 s | 0.03 s | 0.11 s | 0.36 s (10,000) |
| Peak memory | 156 MB | 983 MB | 1.34 GB | 147 MB |

Slower than 2026-11-07's in drawing and Find, with that code unchanged (PdfEngine's open reads through `StaleTail`, 1.9.0),
so the build of 2026-11-08 (`7ff5fad3`) and 1.11.0's were run interleaved on `drawings.pdf`, 3 times each (`one`): first
render 1,509 / 873 / 1,352 ms then, 526 / 754 / 521 ms now; Find 23.9 / 23.0 / 17.4 s then, 17.0 / 17.5 / 20.4 s now; peak
1.34 GB both. The Air's state, not the code. Paragraph editing and Translate add nothing to opening, drawing or Find.

The save with the pass before it (`UnsharePassTimingTests`, opt-in, release build, the corpus): the pass 0.02 s
(`text.pdf`), 0.12 s (`comments.pdf`), 0.01 s (`scan.pdf`, `drawings.pdf`), no copies needed in any; a compacting save
0.05, 0.26, 0.72 and 1.49 s with it, about 0.03, 0.13, 0.71 and 1.48 s without.

## What missed

- `drawings.pdf`: 20 of the first 20 pages took over 200 ms to render (slowest 251 ms; 223 ms on average).
- `drawings.pdf`: find across 400 pages took 9.84 s.

The on-screen scroll (Windows' `scrollbench`) isn't measured on the Mac yet: see README.md.
