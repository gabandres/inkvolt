# Speed benchmark (Mac)

Roadmap 3.6 on the Mac (E16): the corpus and measures of Windows' `pdf/tools/bench`, over PdfCore, so the two apps'
numbers can be put side by side. Results go in [RESULTS.md](RESULTS.md). Builds only on a Mac (PdfCore needs MuPDF's
XCFramework: `sh mac/Vendor/mupdf/build.sh` once).

```sh
swift build -c release --package-path mac/tools/bench
B=mac/tools/bench/.build/release/InkvoltBench
$B make --out ~/inkvolt-bench-corpus          # the corpus, about 1.1 GB, a minute; never in the repo
$B run  --out ~/inkvolt-bench-corpus --reps 3 --md mac/tools/bench/RESULTS.md --note "the machine's state"
$B scale ~/inkvolt-bench-corpus/text.pdf lantern 1 2 4 8   # Find's text reading on n threads, each its own engine
$B bands ~/inkvolt-bench-corpus/drawings.pdf 1 4 8 16      # the first 5 pages drawn in n bands: cold and again, ms a page
$B clean --out ~/inkvolt-bench-corpus
```

From the PC: `bash mac/tools/mac.sh bg bench "…"` with the lines above, then `mac.sh log bench`. Run `make` and `run`
before each Inkvolt PDF for Mac release and commit RESULTS.md. `--small` makes a tiny corpus for trying things out;
`one file word` prints one measurement as JSON (what `run` starts, a fresh process per repetition);
`INKVOLT_BENCH_TRACE=1` prints the peak memory after each step of `one`; `INKVOLT_BENCH_SERIAL=1` measures Find as it was
before E16 (one page after another on the engine's text instance); `jpegsize` prints a scan page's JPEG size at several
ImageIO qualities.

## The corpus (`Corpus.swift`)

The four files of Windows' corpus (its README has the table), ported line by line: the same `Rng` (xorshift64*) with the
same seeds, the same word bank, layout, paths and comments, so the pages show the same words and shapes and Find finds
the same counts (11,011 "lantern" in `text.pdf`, 80 "detail" in `drawings.pdf`, 579 in `comments.pdf`). The bytes are not
Windows': Apple's deflate (the Compression framework, with a zlib header and Adler-32 around it) compresses better than
.NET's (the drawing set is 611 MB, not 1,017 MB), and the scan's pages go through ImageIO's JPEG encoder (quality 0.51,
which gives Windows' 0.86 MB a page) instead of the bench's own. So the SHA-256s differ from Windows' RESULTS.md; two
`make`s on the Mac give the same bytes.

## The measures (`Measures.swift`, `Harness.swift`)

As Windows' (its README), with these differences:
- Read: `PdfEngine.readFile`, as the app's `DocumentSession.open` reads a file (whole; the Mac has no in-place open for
  big files: a 611 MB file is read into memory once, and the engine keeps one copy for all its instances).
- Find: `PdfEngine.findAll`, as the app's Find bar runs it: pages on threads in process, no worker processes.
- Peak memory: the process's peak resident size (`ru_maxrss`), not Windows' working set.
- The on-screen scroll (Windows' `scrollbench` in the dev script) has no Mac counterpart yet: the app's self-test
  doesn't scroll at a set speed. Not measured.
