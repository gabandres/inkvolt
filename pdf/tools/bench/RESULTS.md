# Benchmark results (roadmap 3.6)

Written by `dotnet run --project pdf/tools/bench -c Release -- report` on 2026-10-30. The corpus and the measures are described in
[README.md](README.md); run `make`, `run` and `report` again before a release and commit this file.

- **PC:** Microsoft Surface Laptop, 7th Edition, Snapdragon(R) X 12-core X1E80100 @ 3.40 GHz (12 logical processors), 32 GB RAM, Microsoft Windows 10.0.26300 Arm64, .NET 10.0.14.

## The corpus

| File | What | Size | SHA-256 |
|---|---|---|---|
| `text.pdf` | 5,000-page text document: real paragraphs in Times, Helvetica, Courier and Helvetica-Bold (standard fonts, Flate content) | 8.0 MB | `1d6aa048fa3b78d0…` |
| `scan.pdf` | 500-page scan: 300 dpi grayscale JPEG pages (2550 × 3300 px) with paper noise, text-like lines and specks | 428.2 MB | `50bfafecc72d6468…` |
| `drawings.pdf` | 400-sheet drawing set (ARCH D, 36 × 24 in): hatching, polylines and circles, 72,000 paths per sheet, a title block | 1,017.0 MB | `f5067a3ce4224aef…` |
| `comments.pdf` | 250-page text document with 10,000 comments: notes, highlights, underlines, strike-outs, boxes, circles, ink, text boxes, with popups, and replies | 6.5 MB | `efdfd602a82dbe54…` |

## 2026-10-30, second run: after the speed work (branch `speed`)

- **Build:** commit 2440000, win-arm64, Release (optimized); each measure is the median of 3 runs, each in a fresh process.
- This PC was busy with other builds and sessions during the run (8 or 9 other sessions, CPU near 100%): the numbers are indicative, and a re-run on a quiet PC is expected before the release.

### Measures against the targets

| Measure | Target | `text.pdf` | `scan.pdf` | `drawings.pdf` | `comments.pdf` |
|---|---|---|---|---|---|
| Pages |  | 5,000 | 500 | 400 | 250 |
| First page (read + open + render) | < 1 s | 0.08 s pass | 0.11 s pass | 0.47 s pass | 0.38 s pass |
|   of which: read the file / open / render |  | 4 / 37 / 34 ms | 0 / 22 / 84 ms | 0 / 16 / 457 ms | 4 / 307 / 64 ms |
| Scrolling proxy: 20 pages after a cold open, ms/page (slowest) | no page > 200 ms | 5 ms (16) pass | 27 ms (36) pass | 848 ms (1,066) **miss**, 20 over | 10 ms (22) pass |
| Find a word across all pages | < 5 s | 9.74 s **miss** ("lantern": 11,011 hits) | 0.43 s pass ("lantern": 0 hits) | 164.14 s **miss** ("detail": 80 hits) | 0.72 s pass ("lantern": 579 hits) |
| Comment list ready | < 2 s | 0.37 s pass (0 comments) | 0.17 s pass (0 comments) | 1.99 s pass (0 comments) | 0.90 s pass (10,000 comments) |
| Peak working set | < 1.5 GB | 0.18 GB pass | 0.19 GB pass | 0.16 GB pass | 0.16 GB pass |
| On-screen scroll (app, 4 s at 1,500 px/s): frames per second | 60 fps | 74 fps pass, longest gap 52 ms | 75 fps pass, longest gap 33 ms | 75 fps pass, longest gap 32 ms | 58 fps pass, longest gap 171 ms |
|   frames with a blank page |  | 0 of 297 | 0 of 301 | 84 of 300 | 0 of 231 |
|   pages still blank 200 ms after the scroll stops | none | 0 pass | 0 pass | 0 pass | 0 pass |

### What missed

- `text.pdf`: find across 5,000 pages took 9.7 s.
- `drawings.pdf`: 20 of the first 20 pages took over 200 ms to render (slowest 1,066 ms; 848 ms on average).
- `drawings.pdf`: find across 400 pages took 164.1 s.

### What changed since the first run

- Find reads pages on two threads in page order (`PdfEngine.FindAll`) and remembers every page's text for the
  document's lifetime (whole, with boxes, for pages with little text). More threads don't help: MuPDFCore's native
  wrapper guards MuPDF's allocations with process-wide mutexes, so four instances in one process take four times the
  CPU of one for no gain (four separate processes run four times as fast).
- A file of 256 MB or more opens in place (`PdfEngine.OpenFile`): nothing is read up front, and the bytes are read only
  when something needs them. A name scan of the file lets the comment list (and the app's other readers) skip PDFsharp
  when the file never mentions `/Annots`; on the drawing set that scan of 1 GB is the 1.99 s comment list.
- Renders of 200,000 pixels or more run in four strips on cloned contexts; the viewer shows a 250,000-pixel preview of
  a page before its full render.
- A second search across the drawing set takes about a millisecond (every sheet's text is kept); a second search for
  "lantern" in `text.pdf` still reads the 5,000 pages again, as nearly all of them match.

## 2026-10-30, first run

- **Build:** commit 061f31d, win-arm64, Release (optimized); each measure is the median of 3 runs, each in a fresh process.
- This PC was busy with other builds and sessions during the run: the numbers are indicative, and a re-run on a quiet PC is expected before the release.

### Measures against the targets

| Measure | Target | `text.pdf` | `scan.pdf` | `drawings.pdf` | `comments.pdf` |
|---|---|---|---|---|---|
| Pages |  | 5,000 | 500 | 400 | 250 |
| First page (read + open + render) | < 1 s | 0.06 s pass | 0.27 s pass | 1.47 s **miss** | 0.35 s pass |
|   of which: read the file / open / render |  | 4 / 41 / 18 ms | 213 / 18 / 39 ms | 476 / 13 / 982 ms | 3 / 319 / 30 ms |
| Scrolling proxy: 20 pages after a cold open, ms/page (slowest) | no page > 200 ms | 4 ms (17) pass | 37 ms (46) pass | 1,597 ms (1,705) **miss**, 20 over | 12 ms (22) pass |
| Find a word across all pages | < 5 s | 12.83 s **miss** ("lantern": 11,011 hits) | 0.07 s pass ("lantern": 0 hits) | 194.47 s **miss** ("detail": 80 hits) | 0.93 s pass ("lantern": 579 hits) |
| Comment list ready | < 2 s | 0.43 s pass (0 comments) | 0.23 s pass (0 comments) | 0.63 s pass (0 comments) | 0.79 s pass (10,000 comments) |
| Peak working set | < 1.5 GB | 0.10 GB pass | 1.00 GB pass | 2.08 GB **miss** | 0.12 GB pass |
| On-screen scroll (app, 4 s at 1,500 px/s): frames per second | 60 fps | 73 fps pass, longest gap 43 ms | 74 fps pass, longest gap 36 ms | 75 fps pass, longest gap 41 ms | 56 fps pass, longest gap 99 ms |
|   frames with a blank page |  | 0 of 292 | 0 of 294 | 300 of 300 | 0 of 223 |
|   pages still blank 200 ms after the scroll stops | none | 0 pass | 0 pass | 2 **miss** | 0 pass |

### What missed

- `text.pdf`: find across 5,000 pages took 12.8 s.
- `drawings.pdf`: first page in 1.5 s (reading the file 0.5 s, opening 0.0 s, the render 1.0 s).
- `drawings.pdf`: 20 of the first 20 pages took over 200 ms to render (slowest 1,705 ms; 1,597 ms on average).
- `drawings.pdf`: find across 400 pages took 194.5 s.
- `drawings.pdf`: peak working set 2.08 GB (the file is 1,017.0 MB).
- `drawings.pdf`: on-screen scroll at 75 fps, 2 page(s) still blank 200 ms after the scroll stopped.
