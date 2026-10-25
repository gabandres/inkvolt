# Inkvolt

Folders, licenses and build commands are in `README.md`. The tests that `.github/workflows/test.yml` runs on every
push: `dotnet test Inkvolt.slnx`.

- **Domain terms** and the modules named after them (edit transaction, document export; printer status, printer session,
  printer list, environment): `pdf/GLOSSARY.md`, `print/GLOSSARY.md`.
- **Store release**: `pwsh -File packaging/pack-msix.ps1 -App Pdf|Print -Version x.y.z.0` packs the app, then installs
  and runs this PC's layout (`packaging/smoke-msix.ps1`). Upload only a package whose smoke test passed. Checklists,
  identities and certification history: `pdf/packaging/README.md`, `print/packaging/README.md`.
- **Driving the apps**: Inkvolt PDF's `--script steps.txt` (step list at the top of `pdf/src/InkvoltPdf.App/DevScript.cs`),
  Inkvolt Print's `--demo --snapshot` (`print/README.md`).
- **Export fidelity** (Word, Excel and the other exports): `pdf/tools/export-corpus` (see its README) after any change to
  `DocLayout`, `DocxWriter` or the glyph reading in `PdfEngine`.
