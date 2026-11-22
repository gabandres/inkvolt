# Forms corpus results (Mac)

Inkvolt PDF for Mac on PdfCore, MuPDF 1.25.2, Apple silicon; the latest run, 2026-11-07. How the run works:
[README.md](README.md). `baseline.json` is empty: any failure is new.

## The run

| | Forms | Pass |
|---|---:|---:|
| Real forms (`corpus.json`; 1 XFA-only form skipped: not fillable by design) | 285 | **285 (100%)** |
| Synthetic (`SyntheticForms.swift`) | 32 | **32 (100%)** |
| Real forms with a stale tail (`~tail`) | 285 | **285 (100%)** |
| Real forms with their end cut off (`~cut`) | 285 | **285 (100%)** |

25,739 fields listed in the real forms against 25,751 by pdf.js; 23,742 filled (the 22 encrypted forms with the user
password); 189 typed character by character. No hangs (120 s limit) and no crashes; the slowest form takes 2.3 s.

By source (sound copies): IRS 110, pdf.js test forms 82, qpdf 22, USCIS 18, PDFBox 12, VA 10, OPM 7, pdf-lib 7, states
(CA, NY, NJ, TX, IL), AEAT (Spain) and an OpenOffice sample 15, py-pdf 2: all pass.

App self-test (`--self-test … --edit --only-form-fill --synthetic`): 23 of 23, in the page view's own editor.

What the runs found is fixed with tests (`RealFormTraitTests`, `EncryptedFormFillTests`, `DamagedFormTests`); what differs
from Windows: PLAN.md, "Filling real forms".

## Notes (not failures)

- **Calculations**: in 3 forms none changed after filling (`pdfjs-issue14862`, `tx-comptroller-01-339`, `tx-comptroller-ap201`):
  Windows' RESULTS.md explains them (a constant, taxpayer-number validators).
- **Tab order** is the same after a fill on every form, damaged copies included; the app's self-test checks Tab moving on after each fill.
- **What isn't checked**: how a value looks (font size, clipping) beyond its text being drawn; Acrobat itself;
  XFA-only forms; signing fields (a signature made before a repair is never shown valid: `RepairedFileTests`).
