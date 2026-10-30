# pdf.js check

Roadmap 2.1's test says an edited page must open in Acrobat and pdf.js with the same text. MuPDF (the app's own
engine) reads every edited paragraph back in the unit tests; this tool reads the same files with pdf.js (Mozilla's
viewer, the one in Firefox and most browser-based PDF viewers; `pdfjs-dist` from npm, Apache-2.0), page by page in
the order it reads them, so the test can compare. Acrobat isn't on this PC, so that half of the check isn't run.

```powershell
cd pdf/tools/pdfjs-check
npm ci                                   # once: pdfjs-dist, pinned by package-lock.json (node_modules isn't committed)
node index.mjs some.pdf                   # every page: { pages: [{ page: 1, text: "..." }, ...] } on stdout
node index.mjs some.pdf 2 3              # pages 2 to 3
```

The test (`ParagraphEditTests.EditedParagraphsReadTheSameInPdfJs`) runs only with `INKVOLTPDF_PDFJS=1` set; it skips
itself when `node` or `npm` isn't on the PATH, and runs `npm ci` here when `node_modules` is missing. It edits the
longest paragraph of the test's own sample pages (every alignment, a form XObject, stand-in fonts) and, when
`INKVOLTPDF_CORPUS` points at a folder of PDFs (the export corpus's `.cache`), of each corpus file's first three pages,
then checks pdf.js reads the whole paragraph's words in order and the added words together:

```powershell
$env:INKVOLTPDF_PDFJS = '1'; $env:INKVOLTPDF_CORPUS = 'Z:\PdfDesk\pdf\tools\export-corpus\.cache'
dotnet test pdf/tests/InkvoltPdf.Tests --filter FullyQualifiedName~ReadTheSameInPdfJs
```

Needs Node 20 or later. The edited PDFs are written to a temporary folder and deleted; results go to the test output.
