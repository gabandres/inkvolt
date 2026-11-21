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

It also checks the same documents' **PowerPoint and HTML** exports, written beside the Word ones in `.cache\out`:

| Export | Check | Runs |
|---|---|---|
| .pptx | Open XML SDK validator; as many slides as pages | Always |
| .pptx | PowerPoint opens it without a window, with every slide and shape that was written (a repair fails to open or loses shapes) | When PowerPoint is installed |
| .xlsx | Excel opens it read-only, without a window or a prompt, with every sheet and filled cell the file holds (Excel refuses a file it would repair: a cut-off file, an unclosed cell, an unknown cell type or style all fail) | When Excel is installed |
| .docx, .xlsx, .pptx | LibreOffice opens each and converts it to PDF, headless, with a profile of its own in `.cache` (the .xlsx is written only when the document has tables) | With `-LibreOffice`, where it is installed (or `-Soffice C:\path\soffice.exe`) |
| .html | No active content (script, event attribute, a `src` that isn't an embedded picture); a link only as `<a href>` to an http, https or mailto address (with `rel="noopener noreferrer"`) or a `#page-N` anchor | Always |
| .html | The text reads in the plain-text export's order | Always |
| .html | The W3C's Nu validator, errors only | When Java and `.cache\vnu` are there: `npm install --prefix pdf\tools\export-corpus\.cache\vnu vnu-jar --ignore-scripts` |

A check that can't run says so, doesn't count, and is named again in the last line ("Not run here: ..."). Everything runs on this PC; no document goes to an online service.
`-SkipWord` leaves out Word's page count. **Last run, 2026-11-20, 7 documents, 174 pages:** the validator, PowerPoint
(16.0) and the Nu validator pass on all, the HTML carries 869 links (all web, mail or page anchors; a link over two lines is two), and 3,617 of 3,641
lines read in order (the rest are repeated lines and rows the two exports break differently). Word's page counts are the
baseline's. **2026-11-21, Excel (16.0) added:** it opens all 6 workbooks (the seventh document has no tables) with every
sheet and cell, 132 sheets and 14,241 cells in all; the rest as above. **LibreOffice isn't installed on that PC, so `-LibreOffice` hasn't been run** (it said so). No screen reader
has been run either.

Run it after changing `DocLayout`, `DocxWriter`, `PptxWriter`, `HtmlWriter`, `DocumentExport`, or the glyph reading in `PdfEngine`. Fewer pages is
not automatically better: open the changed exports in `.cache\out` beside their PDFs before you update the baseline.
Needs Word. The PDFs are downloaded to `.cache\` (ignored) and pinned by SHA-256. If a publisher replaces a file, it is
reported as "source changed" and isn't compared until the baseline is updated.

**Seeing what MuPDF reads**: `dotnet bin\Release\net10.0\win-arm64\ExportCorpus.dll glyphs in.pdf out.txt` writes every
text line (`T`), vector box (`V`) and, for a line with loose accents or leader dots, every glyph's box and size (`G`).
This dump found the S-73-S problems: TeX-style accents drawn as separate glyphs, and leader dots that the font maps to
"˛".
