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

## 2026-10-30, fourth run: before the release

- **Build:** commit a900032, win-arm64, Release (optimized); each measure is the median of 3 runs, each in a fresh process.
- Other sessions were open on this PC: total CPU 81% when sampled just before the build and 25% just after the run, so the
  numbers are indicative, and the on-screen frame rates most of all. Same corpus as the third run (the SHA-256s above).

### Measures against the targets

| Measure | Target | `text.pdf` | `scan.pdf` | `drawings.pdf` | `comments.pdf` |
|---|---|---|---|---|---|
| Pages |  | 5,000 | 500 | 400 | 250 |
| First page (read + open + render) | < 1 s | 0.08 s pass | 0.07 s pass | 0.48 s pass | 0.32 s pass |
|   of which: read the file / open / render |  | 4 / 41 / 31 ms | 0 / 25 / 41 ms | 0 / 15 / 463 ms | 3 / 282 / 38 ms |
| Scrolling proxy: 20 pages after a cold open, ms/page (slowest) | no page > 200 ms | 6 ms (15) pass | 26 ms (31) pass | 773 ms (941) **miss**, 20 over | 10 ms (21) pass |
|   the same pages again, engine still holding them: ms/page |  | 4 ms | 4 ms | 587 ms | 7 ms |
| Find a word across all pages | < 5 s | 2.96 s pass ("lantern": 11,011 hits) | 0.45 s pass ("lantern": 0 hits) | 31.39 s **miss** ("detail": 80 hits) | 0.76 s pass ("lantern": 579 hits) |
|   find workers started, pages they read |  | 8 (4,897 pages) | 0 (0 pages) | 8 (396 pages) | 0 (0 pages) |
| Comment list ready | < 2 s | 0.37 s pass (0 comments) | 0.19 s pass (0 comments) | 0.65 s pass (0 comments) | 0.76 s pass (10,000 comments) |
| Peak working set | < 1.5 GB | 0.30 GB pass | 0.18 GB pass | 0.17 GB pass | 0.17 GB pass |
|   with the find workers' peaks added (an upper bound) | < 1.5 GB | 0.90 GB pass | 0.18 GB pass | 0.61 GB pass | 0.17 GB pass |
| On-screen scroll (app, 4 s at 1,500 px/s): frames per second | 60 fps | 75 fps pass, longest gap 42 ms | 74 fps pass, longest gap 42 ms | 75 fps pass, longest gap 19 ms | 53 fps **miss**, longest gap 125 ms |
|   frames with a blank page |  | 0 of 299 | 0 of 297 | 221 of 302 | 0 of 214 |
|   pages still blank 200 ms after the scroll stops | none | 0 pass | 0 pass | 1 **miss** | 0 pass |

### What missed

- `drawings.pdf`: 20 of the first 20 pages took over 200 ms to render (slowest 941 ms; 773 ms on average).
- `drawings.pdf`: find across 400 pages took 31.4 s.
- `drawings.pdf`: on-screen scroll at 75 fps, 1 page(s) still blank 200 ms after the scroll stopped.
- `comments.pdf`: on-screen scroll at 53 fps, 0 page(s) still blank 200 ms after the scroll stopped.

The drawing set's misses are the third run's (the 5 s target is written for a 5,000-page text). `comments.pdf`'s 53 fps is
new against the third run's 58 fps (56 to 58 in every run before): nothing in this build touches scrolling, and three more scrolls of it alone at 26 to 29% CPU gave 58.6, 60.6 and 56.4 fps, so it is the load, not a change.

## 2026-10-30, third run: Find in worker processes

- **Build:** commit 3e8b925, win-arm64, Release (optimized); each measure is the median of 3 runs, each in a fresh process.
- Other sessions were open on this PC, but it was quieter than for the runs below (total CPU 4 to 22% at the moments it was
  sampled before and after each run), so the numbers are indicative, and the drawing set's "before" is the low end of the
  earlier 106 to 164 s. The build before the workers (c8839f7) was run straight after this one, 18:43 to 18:50, on the same
  PC, for the comparison below.

### Before and after

| Find, first search | Before (c8839f7) | With workers | Workers | Peak with workers added |
|---|---|---|---|---|
| `text.pdf`, 5,000 pages | 9.64 s **miss** | 2.71 s pass | 8 | 0.87 GB |
| `drawings.pdf`, 400 sheets | 106.45 s | 31.73 s | 8 | 0.60 GB |
| `scan.pdf`, 500 pages | 0.42 s | 0.55 s | 0 (none started) | 0.19 GB |
| `comments.pdf`, 250 pages | 0.78 s | 0.74 s | 0 (none started) | 0.17 GB |

Hits are the same in both builds (11,011, 0, 80 and 579). The scan's 0.42 and 0.55 s are the same code on either side: no
worker started.

### Measures against the targets

| Measure | Target | `text.pdf` | `scan.pdf` | `drawings.pdf` | `comments.pdf` |
|---|---|---|---|---|---|
| Pages |  | 5,000 | 500 | 400 | 250 |
| First page (read + open + render) | < 1 s | 0.07 s pass | 0.07 s pass | 0.48 s pass | 0.33 s pass |
|   of which: read the file / open / render |  | 4 / 37 / 34 ms | 0 / 21 / 49 ms | 0 / 16 / 467 ms | 4 / 294 / 37 ms |
| Scrolling proxy: 20 pages after a cold open, ms/page (slowest) | no page > 200 ms | 6 ms (16) pass | 25 ms (29) pass | 761 ms (888) **miss**, 20 over | 10 ms (23) pass |
|   the same pages again, engine still holding them: ms/page |  | 4 ms | 4 ms | 581 ms | 7 ms |
| Find a word across all pages | < 5 s | 2.71 s pass ("lantern": 11,011 hits) | 0.55 s pass ("lantern": 0 hits) | 31.73 s **miss** ("detail": 80 hits) | 0.74 s pass ("lantern": 579 hits) |
|   find workers started, pages they read |  | 8 (4,893 pages) | 0 (0 pages) | 8 (396 pages) | 0 (0 pages) |
| Comment list ready | < 2 s | 0.40 s pass (0 comments) | 0.17 s pass (0 comments) | 0.63 s pass (0 comments) | 0.77 s pass (10,000 comments) |
| Peak working set | < 1.5 GB | 0.27 GB pass | 0.19 GB pass | 0.17 GB pass | 0.17 GB pass |
|   with the find workers' peaks added (an upper bound) | < 1.5 GB | 0.87 GB pass | 0.19 GB pass | 0.60 GB pass | 0.17 GB pass |
| On-screen scroll (app, 4 s at 1,500 px/s): frames per second | 60 fps | 74 fps pass, longest gap 38 ms | 75 fps pass, longest gap 33 ms | 75 fps pass, longest gap 24 ms | 58 fps pass, longest gap 91 ms |
|   frames with a blank page |  | 0 of 297 | 0 of 299 | 43 of 302 | 0 of 234 |
|   pages still blank 200 ms after the scroll stops | none | 0 pass | 0 pass | 0 pass | 0 pass |

### What missed

- `drawings.pdf`: 20 of the first 20 pages took over 200 ms to render (slowest 888 ms; 761 ms on average).
- `drawings.pdf`: find across 400 pages took 31.7 s. (The 5 s target is written for a 5,000-page text; a sheet's 72,000 paths
  are still parsed for a text pass that ignores them, some 600 ms a sheet on each of eight workers.)

### How the numbers were decided

One `Bench one` each, on the same day, the load changing between them:

| Workers | `text.pdf` | Their peaks added | `drawings.pdf` | Their peaks added |
|---|---|---|---|---|
| 2 | 5.68 s | 155 MB | | |
| 4 | 2.69 s | 307 MB | 37.48 s | 243 MB |
| 6 | 2.28 s | 461 MB | | |
| 8 | 2.40 s | 605 MB | 30.06 s | 447 MB |

- **How many:** cores less two, at most eight: a long text gains nothing past six, and the drawing set still gains at eight.
  A worker peaks at 77 MB on the text and 56 MB on the drawing set; 100 MB each is budgeted, within half the free memory and
  1.2 GB, so the app and its workers stay under the 1.5 GB target. The parent's peak is 0.27 GB against 0.18 GB, from the
  pages in flight.
- **When:** the search starts on its two threads, and from 200 ms on, once at least 16 pages are left, its pace says how much
  is left. Workers started at once on the 250-page and 500-page files, eight of them: 0.87 s against 0.78 s and 0.47 s
  against 0.42 s, so they don't pay under a second or so, as they are reading some 400 ms after being asked. Hence
  **2 s** left by the pace, about 1,000 pages of a text, with all the workers from 4 s and fewer below that.

### Drawing set: a display list kept per sheet across scrolls

Tried on paper and dropped, as the numbers show it can't help enough. The engine already keeps the last 32 sheets with their
display lists, and rendering the same 20 sheets again takes 581 ms each against 761 ms the first time: the list saves about a
quarter, and the rest is painting 72,000 paths. Keeping more only helps coming back to a sheet more than 32 sheets away, and
never the first look at one. The 200 ms target needs something else (pictures of the sheets kept, or fewer paths painted at
that scale). No code changed for this; `the same pages again` above is the new measure.

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
