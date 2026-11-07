# Forms corpus results (Mac), 2026-11-07

Inkvolt PDF for Mac on PdfCore, MuPDF 1.25.2, Apple silicon. How the run works: [README.md](README.md). The first run was on
master `7e74acfa`, before these fixes.

## The run

| | Forms | Before | After |
|---|---:|---:|---:|
| Real forms (`corpus.json`; 1 XFA-only form skipped: not fillable by design) | 285 | 253 (88.8%) | **285 (100%)** |
| Synthetic (`SyntheticForms.swift`) | 32 | 20 of 31 (1 lost all its fields, read as "no form") | **32 (100%)** |
| Real forms with a stale tail (`~tail`) | 285 | 142 (with these fixes but for `StaleTail`'s signed files) | **285 (100%)** |
| Real forms with their end cut off (`~cut`) | 285 | 80 (the same) | **285 (100%)** |

Two of the 32 real failures before were the harness's (a form's own script refusing its value while typing, and a pdf.js line cut
at 64 KB by a pipe), so the app's own rate before is 255 of 285 (89.5%).

25,739 fields listed in the real forms against 25,751 by pdf.js; 23,742 filled (before: 19,521; the 22 encrypted forms couldn't
be filled); 189 typed character by character. No hangs (120 s limit) and no crashes; the slowest form takes 2.3 s. `baseline.json` is empty.

| Source | Pass, sound copy |
|---|---|
| IRS | 110 / 110 |
| pdf.js test forms | 82 / 82 |
| qpdf test forms | 22 / 22 |
| USCIS | 18 / 18 |
| PDFBox test forms | 12 / 12 |
| VA | 10 / 10 |
| OPM | 7 / 7 |
| pdf-lib test forms | 7 / 7 |
| States (CA, NY, NJ, TX, IL), AEAT (Spain), OpenOffice sample | 15 / 15 |
| py-pdf samples | 2 / 2 |

App self-test (`--self-test … --edit --only-form-fill --synthetic`): 23 of 23, in the page view's own editor.

## Fixed, grouped by root cause

Each has its test, a small made-up form (`RealFormTraitTests`, `EncryptedFormFillTests`, `DamagedFormTests`). The first eight are
what Windows found; the Mac had them all.

1. **Encrypted forms that allow filling: 22 real forms** (17 USCIS, 3 OPM, 2 pdf.js) asked for the owner password. Now filled with
   the user password, the original bytes and an update under the same key: /P bit 9 or 6 to fill, bit 6 for comments; the rest still
   asks. The update reads back in MuPDF and pdf.js, with the same protection (`checkEncryption`).
2. **AFSpecial while typing** (`ca-ftb-540`, SSN and phone): the dashes went into the editor and the MaxLen counted them, so
   `123456789` left `123-45-67`. `AFSpecial_Keystroke` now checks Acrobat's partial patterns and inserts nothing.
3. **A widget its parent's /Kids leaves out: 3 forms** (`pdfjs-opt_demo`, `qpdf-form-errors`, `qpdf-form-document-defaults`).
4. **A choice field's widgets with their own /I and /V** (`pdflib-fancy_fields`).
5. **Check boxes with no face or an empty one** (`pdfjs-checkbox_no_appearance`, `pypdf-pdflatex-forms`).
6. **The same widget on several pages** (`qpdf-form-fields-and-annotations-shared`).
7. **A kid widget without /Parent** (`qpdf-form-document-defaults` · `Text Box 1`): MuPDF showed no value.
8. **A calculation setting its own field through getField; AFSimple, AFExtractNums** (`pdfjs-issue15753`).

Found here, not by Windows' corpus:

9. **A repaired file written whole lost what its object streams hold: 61 of the `~cut` forms lost bookmarks, 44 their tab order**
   (the structure tree went). Real data lost on save: MuPDF's writer doesn't read a repaired file's object streams by itself, and its
   garbage collection dropped them. `MuDoc.write` loads every object first.
10. **A stale tail's old object replaced the real one: 143 of the `~tail` forms** (most lost every field). `StaleTail.normalized`
    cuts the tail as a document opens, unless a signature covers it.
11. **An update after a signed file's junk had wrong offsets; a signed file with a revision cut off was edited from an older
    revision while the view showed the repaired one: 103 of the `~cut` forms lost their values.** The update now goes right after
    the last revision, and only junk with no object in it is dropped; otherwise saving asks for the rewrite.
12. **A comb field's format pushed the last digits out of its cells** (`synth-special`): `123-45-67`. The cells show what was typed.

Also: a form's `/ByteRange` search spent a quarter of a fill on a 575 KB file (`DataProtocol.firstRange`, byte by byte): `PdfBytes`.

## Notes (not failures)

- **Calculations**: in 3 forms none changed after filling (`pdfjs-issue14862`, `tx-comptroller-01-339`, `tx-comptroller-ap201`):
  Windows' RESULTS.md explains them (a constant, taxpayer-number validators).
- **Tab order** is the same after a fill on every form, damaged copies included; the app's self-test checks Tab moving on after each fill.
- **What isn't checked**: how a value looks (font size, clipping) beyond its text being drawn; Acrobat itself (not on this Mac);
  XFA-only forms; signing fields; whether a signature made before a repair shows valid (Windows' rule isn't ported).
