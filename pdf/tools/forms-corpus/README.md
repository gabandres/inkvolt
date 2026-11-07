# Forms corpus

Unit tests fill forms the tests made. Real forms come from LiveCycle, Acrobat, Word, LibreOffice, pdfTeX and a dozen
libraries, encrypted or not, with JavaScript formats and calculations, and some of them can't be filled at all. This tool
fills about 300 public forms through the app's own fill path and reads them back three ways, so a form that fails is
found here before a user finds it.

```powershell
pwsh -File pdf/tools/forms-corpus/fetch.ps1          # once: downloads corpus.json's forms to .cache\pdfs (ignored), checks SHA-256
dotnet run --project pdf/tools/forms-corpus -c Release -- run                    # all forms; summary in .cache\out\summary.md
dotnet run --project pdf/tools/forms-corpus -c Release -- run --only irs-fw9,synth-js-es
dotnet run --project pdf/tools/forms-corpus -c Release -- run --files C:\x\form.pdf   # also a user's file: never baselined or committed
dotnet run --project pdf/tools/forms-corpus -c Release -- run --update-baseline       # accept the run's failures (after a fix)
dotnet run --project pdf/tools/forms-corpus -c Release -- dump <file.pdf> <field>     # a field as FormEditor and the raw widgets see it
pwsh -File pdf/tools/forms-corpus/run-ui.ps1         # the UI pass: the app itself, mouse and keys, on 20 sample forms
```

**What a run does, per form** (each in its own process, killed after 120 s: a hang):

1. `FormEditor.Read` (the page view's widgets) and `FormEditor.DataFields` list the fields; pdf.js lists them too
   (`pdfjs-fields.mjs`, pdfjs-dist from `../pdfjs-check`: `npm ci` there once). A field pdf.js shows that Inkvolt doesn't,
   or fewer visible widgets of it, is a failure.
2. Every field that isn't read-only or calculated gets a value, through `FormEditor.Fill` as the page view's typing does:
   text `Ink<n>` (two lines when multiline), digits for AFNumber fields, `1007,5` for Spanish formats (sepStyle 2 and 3),
   a date in the field's own AFDate format, ZIP/phone/SSN for AFSpecial, a mask's own shape, `123456789` for comb fields,
   shortened to MaxLen; check boxes ticked, the last radio button chosen, the second choice picked. A value a script
   refuses is tried again as `1234`, `1`, then a date.
3. The filled file is saved and reopened: each value read back by FormEditor, pdf.js (which also says whether each
   widget has an appearance) and MuPDF (its text of the page, annotations included, must show each text value as its
   format script shows it). Each widget's appearance stream is also read directly: check boxes and radios show the state
   they were set to, text and combo fields draw the value.
4. Fields nobody filled must keep their values (when the form has no scripts). Calculated fields that didn't change
   are noted, not failed.

Failures are grouped by signature (`summary.md`): the kind, plus the exception and first Inkvolt frame, or the field's
kind and format. `baseline.json` holds each failing form's groups: `run` exits 1 when a form fails in a way the baseline
doesn't list, so the opt-in test `FormsCorpusTests` (`INKVOLTPDF_FORMS=1`) catches new failures and stays green as old
ones are fixed. Last results: `RESULTS.md`.

**The corpus** (`corpus.json`: URL, SHA-256, license, source): IRS, USCIS, OPM and VA forms, state tax and DMV forms
(CA, NY, NJ, IL, TX, VA, MN...), Spain's AEAT; the AcroForm test files of pdf.js, PDFBox and qpdf (Apache-2.0) and
pdf-lib (MIT); py-pdf's LibreOffice and pdfTeX forms; OpenOffice's sample form; and `synth-*`, small forms written by
`SyntheticForms.cs` for traits the real ones have too few of (comb, hex and UTF-16 names, inherited /FT and /DA, a.b.c
names, NeedAppearances, missing appearances, rich text, choice pairs, radio kids, check box /Opt, Spanish AFNumber with
a calculation, an incremental update, an object stream, a turned page). The PDFs stay out of git: their licenses either
don't allow redistribution or say nothing. Publishers replace files (the IRS each year): `fetch.ps1` reports a changed
SHA-256 and the run skips that form ("source changed") until `fetch.ps1 -Pin` takes the new one (delete its pin first).
SSA's forms aren't here: ssa.gov refuses scripted downloads.

Downloads are untrusted: they are only ever read as PDFs, by the harness, pdf.js and MuPDF. Nothing goes to an online
service.
