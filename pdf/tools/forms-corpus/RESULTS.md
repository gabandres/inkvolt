# Forms corpus results, 2026-11-07

Inkvolt PDF at `0130d570` (master before this branch), Windows on ARM. How the run works: `README.md`.

## Library path (`FormEditor.Read` / `Fill`, as the page view uses them)

**303 forms in the corpus; 302 run (1 XFA-only form skipped: not fillable by design); 273 pass (90.4%), 29 fail.**
25,784 fields listed by Inkvolt against 25,795 by pdf.js; 19,563 filled (every field that isn't read-only or
calculated). No hangs (120 s limit) and no crashes. 72 forms carry JavaScript (formats, keystrokes, calculations).

| Source | Pass |
|---|---|
| IRS | 110 / 110 |
| pdf.js test forms | 78 / 82 |
| qpdf test forms | 19 / 22 |
| USCIS | 1 / 18 |
| Synthetic (`SyntheticForms.cs`) | 17 / 17 |
| PDFBox test forms | 12 / 12 |
| VA | 9 / 9 |
| OPM | 4 / 7 |
| pdf-lib test forms | 6 / 7 |
| States (CA FTB, CA EDD, CA DMV, NY, NJ, TX, IL, VA), AEAT (Spain), OpenOffice sample | 18 / 18 |
| py-pdf samples (LibreOffice, pdfTeX) | 1 / 2 |

Spanish number formats work through `Fill`: `1007,5` typed into AFNumber sepStyle 2 shows `1.007,50`, sepStyle 3
`1007,50 €`, and the SUM / product calculations update (`synth-js-es`, `synth-js-es3`, `ca-dmv-reg227`).

## UI path (`run-ui.ps1`: the app, real mouse clicks and keys, Ctrl+S)

20 sample forms, up to 8 fields each: **19 keep every value**. One fails, in a way the library path can't show (below,
group 2).

## Failures, grouped by root cause, most forms first

Each with the smallest public example. "Fail" groups in `.cache\out\summary.md` map onto these.

1. **Encrypted forms that allow filling can't be filled: 22 forms** (17 USCIS, 3 OPM, 2 pdf.js). `FormEditor.Fill`
   opens the file in PDFsharp's Modify mode, which demands the permissions (owner) password
   (`OwnerPasswordRequiredException` from `PdfObj.Open`); the page view's edit transaction then asks the user for that
   password, which a form's user never has. These files open without a password and their /P allows form filling
   (USCIS: /P -1036, bit 9 set); Acrobat and Nitro fill them. Smallest: `pdfjs-secHandler` (7.8 KB); public:
   `uscis-g-1145`, any field. *Worth checking against the owner's failing form first: it fits "can't fill at all".*

2. **Typing into an AFSpecial field with a MaxLen equal to its digits is refused: page view only** (1 of 20 UI forms;
   likely every SSN, phone and ZIP+4 field built this way, common on state tax forms). On `ca-ftb-540`, field
   `540-1007` (AFSpecial SSN, comb, MaxLen 9), typing `123456789` gives `123-45-67` in the editor: the keystroke path
   inserts the dashes while typing and MaxLen then counts them, so the commit fails the format and the form alerts
   "The value entered does not match the format of the field". `FormEditor.Fill("123456789")` is accepted and shows
   `123-45-6789`, as in Acrobat (whose AFSpecial_Keystroke checks digits while typing and leaves the dashes to the
   format script).

3. **A widget its parent doesn't list in /Kids becomes a separate field `fieldN_pM`: 3 forms.** `FormEditor.Collect`'s
   page fallback stops climbing at a parent already walked, so the widget is named `field1_p1`... instead of joining
   its parent; the real field (`veg`) has no widgets, the radio buttons don't exclude each other, and the value goes to
   the made-up name. Shows as `field-not-found`, `pdfjs-field-missing-after-save`, `widget-not-shown`. Smallest:
   `pdfjs-opt_demo` · `veg` (radio, parent with /Opt and no /Kids); also `qpdf-form-errors` (`r2`),
   `qpdf-form-document-defaults` (`r1.choice1`).

4. **A choice field's widgets keep their own stale /I: 1 form.** `SetChoice` updates /V and the field's /I, but widgets
   carrying their own /I keep the old index; pdf.js (and other readers that take the widget's /I) shows the old choice.
   `pdflib-fancy_fields` · `Choose A Gundam 🤖` (set to Kyrios, pdf.js shows Dynames).

5. **A check box with no appearance and no /MK gets no face when ticked: 1 form.** The value is stored, but nothing
   draws the tick (NeedAppearances stays set, so pdf.js redraws it; Preview, iOS and print pipelines show it empty).
   `pdfjs-checkbox_no_appearance` · `cbOn`.

6. **A check box whose on face isn't a stream is kept as is: 1 form.** pdfTeX wrote /AP /N /Yes as an empty
   dictionary; once ticked nothing shows (pdf.js: no appearance). `EnsureStateFaces` only redraws single-stream or
   missing faces; this one could be redrawn from its /MK /CA. `pypdf-pdflatex-forms` · `Check`.

7. **The same widget on several pages is shown once: 1 form** (malformed: an annotation belongs to one page; pdf.js
   shows it on each). `qpdf-form-fields-and-annotations-shared` · `Text Box 1`, `r1`.

8. **MuPDF doesn't read the filled value: 1 form, cause not yet confirmed.** The appearance stream draws `(Ink1)` with
   /F2, the form's non-embedded TrueType LiberationSans from /DR, yet MuPDF's text of the page doesn't contain it.
   Needs a look at the rendered page. `qpdf-form-document-defaults` · `Text Box 1`.

## Notes (not failures)

- **Calculations**: 14 forms have calculated fields; in 4 none changed after filling every input
  (`tx-comptroller-01-339`, `tx-comptroller-ap201`, `pdfjs-issue14862`, `pdfjs-issue15753`). Not investigated: the
  inputs filled may not feed them.
- **Value refusals**: a value a script refuses is tried again as `1234`, `1`, then a date; none stayed refused in the
  final run.
- **What isn't checked**: how a value looks (font size, clipping, comb spacing) beyond its text being drawn; Acrobat
  itself (not on this PC); XFA-only forms; signing fields.
- **Harness bugs found and fixed while building it** (so they aren't counted above): pdf.js names radio buttons by
  their /Opt export value; combo boxes draw the display text, not the export value; WinAnsi € is byte 0x80; AFNumber
  with no decimals rounds `1427,5` to `1428`; a widget without /Parent is named from /Fields; buttons sharing an export
  value on several pages turn on one at a time; the dev script's `save` step doesn't wait for queued fills (Ctrl+S does).
