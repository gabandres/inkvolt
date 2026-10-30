# OCR corpus

Roadmap item 2.2 (Better OCR) promises a lower word error rate than before on scans that are skewed 3-10°, noisy and in
two languages. Unit tests check the cleanup on pictures; nothing in them says what Windows' recognizer makes of a page
before and after. This tool makes such a corpus, recognizes it both ways and writes the result into
[RESULTS.md](RESULTS.md).

```powershell
dotnet run --project pdf/tools/ocr-corpus -c Release -- make     # write the corpus into %LOCALAPPDATA%\Inkvolt\ocr-corpus
dotnet run --project pdf/tools/ocr-corpus -c Release -- run      # make what's missing, measure every file, write RESULTS.md
dotnet run --project pdf/tools/ocr-corpus -c Release -- report   # RESULTS.md again from the last run's results.json
```

Run `run` after changing `ScanCleanup.cs`, `Deskew` in `PageImage.cs`, `ScanText.cs` or `WindowsRecognizer.cs`, and
commit RESULTS.md. `--out dir` puts the corpus elsewhere; `--note text` adds a line to RESULTS.md. It exits 1 when stage A
isn't lower than today's on every file (the roadmap's test). It needs the en-US and es-MX OCR languages (Settings › Time &
language › Language & region; a language's options, Optical character recognition); without es-MX the Spanish files are
read with the default language.

## The corpus (`ScanCorpus.cs`)

Nothing is copyrighted or personal, and nothing is committed: each file is generated, deterministically (a seeded `Rng`
from `tools/bench`, no dates), so the SHA-256 in RESULTS.md says which corpus a number came from. Made-up prose from a
word bank (English, and Spanish with every accent and ñ, ü), with numbers, a heading per page, typeset in a standard
font, rendered at 300 dpi by MuPDF (its built-in fonts: the same pixels on any PC, the Mac too), then "scanned": turned on
the glass, skewed (both ways), softened by a 3 × 3 blur, put on off-white paper shaded towards one side, given Gaussian
noise, dust and toner specks and a few hairs, and saved as a grey JPEG (quality 70) in a PDF. Two pages a file:

| File | What |
|---|---|
| `en-skew3-light` | English, Times 11 pt, skew 3-4°, light noise |
| `en-skew6-noisy` | English, Helvetica 10 pt, skew 5-7°, heavy noise and 1,500 specks a page |
| `en-skew10-shaded` | English, Times 10 pt, skew 8.5-10°, paper 60 levels darker on one side |
| `es-skew4-noisy` | Spanish, Helvetica 11 pt, skew 3.5-5°, heavy noise |
| `es-skew8-shaded` | Spanish, Times 11 pt, skew 7-9°, shaded paper |
| `en-turned` | English, skew 3-5°, one page upside down and one turned a quarter |

`OcrCorpusTests` (pdf/tests) checks the generator gives the same bytes twice and `WordErrorRate`'s arithmetic;
`ScanCleanupTests` and `ScanTextTests` use its pages.

## The measure (`Program.cs`, `WordErrorRate.cs`)

Word error rate: the fewest word substitutions, deletions and insertions that turn the recognized words into the true
ones, over the number of true words. Words are compared exactly (case, accents and punctuation count, as a search sees
them), in the order recognized. Three readings per file, all with Windows' recognizer through `ScanText.Recognize`:

- **Today**: as Recognize Text read pages before 2.2 (`RecognizeOptions.AsScanned`: the page as rendered, no cleaning),
  in Windows' default language (this PC's: en-US).
- **Today, its language chosen**: the same, in the file's language (es-MX for the Spanish files), to tell what the
  language choice alone gives from what the cleaning gives.
- **Stage A**: the file's language, the page cleaned first (straightened, turned upright, smoothed, paper whitened,
  specks removed).

The cleanup's settings came from trying variants on this corpus: whitening at 86% of the paper level cost thin serifs
(the light file got worse, 1.8% → 2.5%); 92% with the median and despeckling was lower on every file.
