# Forms corpus results, 2026-11-07

Windows on ARM. How the run works: `README.md`.

## Library path (`FormEditor.Read` / `Fill`, as the page view uses them)

**303 forms in the corpus; 302 run (1 XFA-only form skipped: not fillable by design); 302 pass, none fail.** 25,783
fields listed by Inkvolt against 25,795 by pdf.js; 23,784 filled (every field that isn't read-only or calculated). No
hangs (120 s limit) and no crashes. 72 forms carry JavaScript (formats, keystrokes, calculations). `baseline.json` is
empty: any failure is new.

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

20 sample forms, up to 8 fields each: **20 keep every value**. Under load a save can take longer than the script's 5 s
after Ctrl+S (the form then shows unsaved changes with its values in the fields); run such a form again alone before
calling it a failure.

## What the corpus taught the fill path (each with its unit test)

1. **Encrypted forms that allow filling** are filled with the user password (empty, or the open password typed), as
   Acrobat, Nitro and Preview do (`UserPasswordEdits`): the save is an incremental update of the encrypted original that
   keeps /Encrypt and /ID, new objects encrypted with the file key (`StandardCrypt`: RC4 and AES-128 at revisions 2-4,
   AES-256 at 5 and 6). Filling needs /P bit 9 or bit 6, comments bit 6; anything else still asks for the owner
   password, and such a document is never written whole. The update writes the encryption dictionary again, since
   PDFsharp can't read a file whose third trailer names an /Encrypt only an older section defines (Acrobat's updates do
   that; `PdfObj.Read` reads them). `EncryptedFormFillTests`.
2. **AFSpecial fields while typing**: `AFSpecial_Keystroke` checks the text so far against Acrobat's partial patterns,
   so an SSN field with MaxLen 9 takes `123456789` and shows `123-45-6789`; /V keeps what was typed, as Acrobat stores it.
3. **A widget its parent doesn't list in /Kids** joins its /Parent field, and a field's nameless kids beside named ones
   are its own widgets (`RealFormTraitTests`).
4. **A choice field's widgets with their own /I and /V**: dropped when the field is set.
5. **Check box faces and shared widgets**: a ticked box with no appearance gets the default tick; pdfTeX's on face that
   isn't a stream is redrawn from /MK; a widget on several pages' /Annots is on each. A field's only widget without
   /Parent (MuPDF doesn't take it for the field's) gets /Parent when the field is written.

## Calculations

14 forms have calculated fields; in 3 none change after filling, and none of those is Inkvolt's to fix:
- `tx-comptroller-01-339`, `tx-comptroller-ap201`: the "calculations" are `TPNvalid(...)`, a taxpayer number
  check-digit validator that alerts and never sets a value. ap201's other one, `Language`, shows and hides
  instruction fields by names (`in0a`...) the form doesn't have: it fails at its first line in Acrobat too.
- `pdfjs-issue14862`: resets itself and sets 123 whatever is filled (pdf.js's test for a calculation loop).

A calculation that sets its own field through `getField("Field2").value` instead of `event.value` keeps the value, as
Acrobat does (`pdfjs-issue15753`). Everything these forms use runs in the JavaScript sandbox (Jint, with `AFSimple` and
`AFExtractNums` among the AF helpers).

## Notes (not failures)

- **Value refusals**: a value a script refuses is tried again as `1234`, `1`, then a date; none stayed refused.
- **What isn't checked**: how a value looks (font size, clipping, comb spacing) beyond its text being drawn; Acrobat
  itself (not on this PC); XFA-only forms; signing fields; AES-256 revision 5 (deprecated; no producer in the corpus
  or in PDFsharp writes it).
- **The harness's own traps** (fixed in it): pdf.js names radio buttons by their /Opt export value; combo boxes draw the
  display text, not the export value; WinAnsi € is byte 0x80; AFNumber with no decimals rounds `1427,5` to `1428`; a
  widget without /Parent is named from /Fields; buttons sharing an export value on several pages turn on one at a time;
  the dev script's `save` step doesn't wait for queued fills (Ctrl+S does).
