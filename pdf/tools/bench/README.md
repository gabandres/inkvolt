# Speed benchmark

Roadmap item 3.6 promises numbers on huge files, published with each release. Unit tests open small PDFs; nothing in
them says what a 5,000-page document or a gigabyte of drawings does to the first page, to scrolling, to Find or to the
Comments pane. This tool makes that corpus, measures the Core on it and writes the result into [RESULTS.md](RESULTS.md).

```powershell
dotnet run --project pdf/tools/bench -c Release -- make      # write the corpus (about 1.5 GB, 2 minutes) into %LOCALAPPDATA%\Inkvolt\bench
dotnet run --project pdf/tools/bench -c Release -- run       # measure every file 3 times, scroll it in the app, write RESULTS.md
dotnet run --project pdf/tools/bench -c Release -- report    # RESULTS.md again from the last run's results.json
```

Run `make` and `run` before each release (after `dotnet build pdf/src/InkvoltPdf.App -c Release`, so the on-screen
scroll runs too), read what missed, and commit RESULTS.md. `--out dir` puts the corpus elsewhere; `--reps n` changes the
repetitions; `--app path\InkvoltPdf.exe` names the app (`--app none` skips the on-screen scroll); `--note text` adds a
line to RESULTS.md (the state of the PC, for instance). `--small` makes a tiny corpus for trying things out. The corpus
is never committed: each file is deterministic (`Rng` seeded by page number, no dates), so its SHA-256 in RESULTS.md
says which corpus a number came from.

## The corpus (`Corpus.cs`)

Written straight to disk by `PdfFileWriter` (object by object, a classic xref), so the gigabyte file never sits in memory.

| File | What | Why |
|---|---|---|
| `text.pdf` | 5,000 Letter pages of made-up prose (`Prose`: a 200-word bank; "lantern" is the search word), headings, an italic paragraph, a footer; Times, Helvetica, Courier, Helvetica-Bold and Times-Italic as standard fonts; Flate content | Find across 5,000 pages; the first page and scrolling of a long book |
| `scan.pdf` | 500 pages, each a 2550 × 3300 grayscale JPEG (300 dpi) made by `JpegEncoder` (a baseline encoder, Annex K tables, so no image library is needed): paper noise, a slight shading, lines of word-shaped blobs, specks; about 0.9 MB a page | Scrolling a scan: every page decodes a large JPEG |
| `drawings.pdf` | 400 ARCH D sheets (36 × 24 in), 72,000 paths each (hatching strokes, polylines, circles; colors and widths change every 400 paths), a grid, a title block ("A-101  DETAIL PLAN, NORTH WING"; "detail" is the search word); about 1 GB | A drawing set: vector-heavy pages, a file the size of the memory target |
| `comments.pdf` | 250 text pages with 40 comments each (10,000): notes, highlights, underlines, strike-outs, boxes, circles, ink, text boxes (each with an appearance stream and a popup), and replies (`/IRT`) to the first ones on each page | The Comments pane reading everything through PDFsharp |

## The measures (`Measures.cs`, `Harness.cs`)

Core level, Release build, each file measured in a fresh child process 3 times; RESULTS.md shows the median. A page is
rendered at `Measures.ScaleFor`: 100% zoom on a 150% display (2 px per point) for ordinary pages, fit to 1,200 px for
wide sheets.

| Measure | How | Target (ROADMAP 3.6) |
|---|---|---|
| First page | `File.ReadAllBytes` + `PdfEngine.Open` + `Render(0)` | under 1 s |
| Scrolling proxy | a fresh engine renders pages 1–20 one after another; ms/page, the slowest, and how many took over 200 ms | no page over 200 ms |
| Find | `FindAll(word)`, as the app's search does (pages read on two threads, in order; text remembered for the next search) | under 5 s across 5,000 pages |
| Comment list | `Annotations.Read` on the file's bytes, as the Comments pane does when a file opens | under 2 s |
| Peak working set | the child process's `PeakWorkingSet64` after all of the above | under 1.5 GB |
| On-screen scroll | the app's dev script `scrollbench 4000 1500` (`DevScript.cs`): 4 s at 1,500 px/s, one step per rendered frame; frames per second, the longest gap, frames that showed a page with no picture yet, pages still blank 200 ms after the stop | 60 fps, no blank page after a 200 ms pause |

`run` finds the app's Release build under `src/InkvoltPdf.App/bin/Release` on its own. Without it, scrolling is measured
by hand (RESULTS.md says so): open the file, scroll a page a second for 10 s, count pages still blank 200 ms after stopping.

`BenchTests` (`INKVOLTPDF_BENCH=1 dotnet test pdf/tests/InkvoltPdf.Tests`) makes a small corpus, opens every file, runs the
measures and checks the corpus is byte-for-byte the same twice, so the generator and harness keep working between releases.

`dotnet pdf/tools/bench/bin/Release/net10.0/win-arm64/Bench.dll png file.pdf 3 out.png` renders a page at 72 dpi to look
at a corpus file; `one file.pdf word` prints one measurement as JSON (what `run` spawns).
