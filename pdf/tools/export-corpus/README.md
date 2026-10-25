# Export corpus

Unit tests check the export's XML and its rules on made-up lines. They can't tell you that a real form came out as three
pages of broken text. That is how the S-73-S form went wrong in October 2026, with 999 tests passing. This tool exports
real public PDFs to Word with the current code and has Word count the pages. A layout regression usually shows up as
extra pages: text that leaves its frames, rows that wrap, spacing that grows.

```powershell
pwsh -File pdf/tools/export-corpus/run.ps1                      # export, count, compare with baseline.json (fails on more pages)
pwsh -File pdf/tools/export-corpus/run.ps1 -Files C:\x\form.pdf # also a user's file: counted, never baselined or committed
pwsh -File pdf/tools/export-corpus/run.ps1 -UpdateBaseline      # accept the new counts once the exports look right
```

Run it after changing `DocLayout`, `DocxWriter`, `DocumentExport`, or the glyph reading in `PdfEngine`. Fewer pages is
not automatically better: open the changed exports in `.cache\out` beside their PDFs before you update the baseline.
Needs Word. The PDFs are downloaded to `.cache\` (ignored) and pinned by SHA-256. If a publisher replaces a file, it is
reported as "source changed" and isn't compared until the baseline is updated.

**Seeing what MuPDF reads**: `dotnet bin\Release\net10.0\win-arm64\ExportCorpus.dll glyphs in.pdf out.txt` writes every
text line (`T`), vector box (`V`) and, for a line with loose accents or leader dots, every glyph's box and size (`G`).
This dump found the S-73-S problems: TeX-style accents drawn as separate glyphs, and leader dots that the font maps to
"˛".
