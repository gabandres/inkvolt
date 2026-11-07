# Forms corpus results, 2026-11-07

Inkvolt PDF at branch `t3/4b146370` (the fixes below, on master `f747b5f4`), Windows on ARM. How the run works:
`README.md`. The first run (master `0130d570`, before these fixes): 273 of 302 passed; what failed and what fixed it is
under "Fixed" below.

## Library path (`FormEditor.Read` / `Fill`, as the page view uses them)

**303 forms in the corpus; 302 run (1 XFA-only form skipped: not fillable by design); 302 pass (100%), none fail**
(before: 273, 90.4%). 25,783 fields listed by Inkvolt against 25,795 by pdf.js; 23,784 filled (every field that isn't
read-only or calculated; before: 19,563, the 22 encrypted forms couldn't be filled). No hangs (120 s limit) and no
crashes. 72 forms carry JavaScript (formats, keystrokes, calculations). `baseline.json` is empty: any failure is new.

| Source | Pass |
|---|---|
| IRS | 110 / 110 |
| pdf.js test forms | 82 / 82 |
| qpdf test forms | 22 / 22 |
| USCIS | 18 / 18 |
| Synthetic (`SyntheticForms.cs`) | 17 / 17 |
| PDFBox test forms | 12 / 12 |
| VA | 9 / 9 |
| OPM | 7 / 7 |
| pdf-lib test forms | 7 / 7 |
| States (CA FTB, CA EDD, CA DMV, NY, NJ, TX, IL, VA), AEAT (Spain), OpenOffice sample | 18 / 18 |
| py-pdf samples (LibreOffice, pdfTeX) | 2 / 2 |

Spanish number formats work through `Fill`: `1007,5` typed into AFNumber sepStyle 2 shows `1.007,50`, sepStyle 3
`1007,50 €`, and the SUM / product calculations update (`synth-js-es`, `synth-js-es3`, `ca-dmv-reg227`).

## UI path (`run-ui.ps1`: the app, real mouse clicks and keys, Ctrl+S)

20 sample forms, up to 8 fields each: **20 keep every value** (before: 19; `ca-ftb-540`'s SSN box, group 2 below).
In the first of two full runs, two forms (`pdflib-fancy_fields`, `synth-inherited`) weren't saved within the script's
5 s after Ctrl+S (the app still showed unsaved changes, the values were in the fields); both passed alone, by hand and
in the second full run. A slow save under load, not a lost value: worth a longer wait in the script if it recurs.

## Fixed (each group with its unit test, a small made-up form)

1. **Encrypted forms that allow filling: 22 forms** (17 USCIS, 3 OPM, 2 pdf.js) asked for the permissions (owner)
   password. Now filled with the user password (empty, or the open password typed), as Acrobat, Nitro and Preview do:
   `UserPasswordEdits` reads the file with it, opens a decrypted copy with the same object numbers, and the save is an
   incremental update of the encrypted original that keeps /Encrypt and /ID, the new objects encrypted with the file
   key from the user password (`StandardCrypt`: RC4 and AES-128 at revisions 2-4, AES-256 at 5 and 6). Filling needs
   /P bit 9 or bit 6, comments bit 6; anything else still asks for the owner password, and such a document is never
   written whole. The update writes the encryption dictionary again: PDFsharp can't read a file whose third trailer
   names an /Encrypt only an older section defines (Acrobat's updates do that; `PdfObj.Read` now reads them too).
   Saved files open, show and read back in MuPDF, pdf.js and PDFsharp, and a second fill appends again.
   `EncryptedFormFillTests`.
2. **AFSpecial fields while typing** (page view): `AFSpecial_Keystroke` checks the text so far against Acrobat's
   partial patterns and inserts nothing, so `540-1007` (SSN, MaxLen 9) takes `123456789` and shows `123-45-6789`;
   /V keeps what was typed, as Acrobat stores it. `FormActionTests.SpecialFieldsTakeTheirDigitsWithinMaxLen...`.
3. **A widget its parent doesn't list in /Kids: 3 forms.** It joins its /Parent field (`pdfjs-opt_demo` · `veg`,
   `qpdf-form-errors` · `r2`), and a field's nameless kids beside named ones are its own widgets
   (`qpdf-form-document-defaults` · `r1`). `RealFormTraitTests`.
4. **A choice field's widgets with their own /I and /V** (`pdflib-fancy_fields`): dropped when the field is set.
5. **Check box faces and shared widgets.** A ticked box with no appearance gets the default tick
   (`pdfjs-checkbox_no_appearance`); pdfTeX's on face that isn't a stream is redrawn from /MK (`pypdf-pdflatex-forms`);
   a widget on several pages' /Annots is on each (`qpdf-form-fields-and-annotations-shared`). MuPDF not showing
   `qpdf-form-document-defaults` · `Text Box 1`: not /DA or /DR, but its only widget has no /Parent (the field lists it
   in /Kids), so MuPDF doesn't take it for the field's widget; it gets /Parent when the field is written.

## Calculations

14 forms have calculated fields; in 3 none changed after filling, and none of those is Inkvolt's to fix:
- `tx-comptroller-01-339`, `tx-comptroller-ap201`: the "calculations" are `TPNvalid(...)`, a taxpayer number
  check-digit validator that alerts and never sets a value. ap201's other one, `Language`, shows and hides
  instruction fields by names (`in0a`...) the form doesn't have: it fails at its first line in Acrobat too.
- `pdfjs-issue14862`: resets itself and sets 123 whatever is filled (pdf.js's test for a calculation loop).

`pdfjs-issue15753` was one of the four: its calculation sets its own field through `getField("Field2").value`
instead of `event.value`, which Acrobat keeps; now Inkvolt does. `AFSimple` and `AFExtractNums` were the documented
AF helpers missing. Everything else these forms use runs in the JavaScript sandbox (Jint, a full engine): nothing
seen needs more than it.

## Notes (not failures)

- **Value refusals**: a value a script refuses is tried again as `1234`, `1`, then a date; none stayed refused in the
  final run.
- **What isn't checked**: how a value looks (font size, clipping, comb spacing) beyond its text being drawn; Acrobat
  itself (not on this PC); XFA-only forms; signing fields; AES-256 revision 5 (deprecated; no producer in the corpus
  or in PDFsharp writes it).
- **Harness bugs found and fixed while building it** (so they aren't counted above): pdf.js names radio buttons by
  their /Opt export value; combo boxes draw the display text, not the export value; WinAnsi € is byte 0x80; AFNumber
  with no decimals rounds `1427,5` to `1428`; a widget without /Parent is named from /Fields; buttons sharing an export
  value on several pages turn on one at a time; the dev script's `save` step doesn't wait for queued fills (Ctrl+S does).
