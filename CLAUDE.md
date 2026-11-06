# Inkvolt

Folders, licenses and build commands are in `README.md`. The tests that `.github/workflows/test.yml` runs on every
push: `pwsh -NoProfile -File tools/test.ps1` (`dotnet test Inkvolt.slnx`; a test that fails under load is run again alone
and named as flaky).

- **Domain terms** and the modules named after them (edit transaction, document export; printer status, printer session,
  printer list, environment): `pdf/GLOSSARY.md`, `print/GLOSSARY.md`.
- **Store release**: `pwsh -NoProfile -File packaging/pack-msix.ps1 -App Pdf|Print -Version x.y.z.0` packs the app, then installs
  and runs this PC's layout (`packaging/smoke-msix.ps1`; add `-SmokeSideBySide` while the Store copy is installed here).
  Upload only a package whose smoke test passed. The release steps in order (bench, What's New, upload, release notes,
  tag, website), identities and certification history: `pdf/packaging/README.md` "Upload", `print/packaging/README.md`.
- **Agents**: `docs/agents/BRIEF.md` (how every agent works and reports). **Review** of a diff before a merge:
  `CODING_STANDARDS.md`.
- **In a worktree** (agents): change files with Edit or Write, and run a script saved as a file (`python -I <file>`):
  the worktree guard refuses heredocs and generated input piped into python, sed or xxd.
- **Driving the apps**: Inkvolt PDF's `--script steps.txt` (step list at the top of `pdf/src/InkvoltPdf.App/DevScript.cs`),
  Inkvolt Print's `--demo --snapshot` (`print/README.md`).
- **macOS apps** (native Swift; Inkvolt PDF for Mac released, Inkvolt Print for Mac 1.1 in the Mac App Store): `mac/CLAUDE.md`.
- **Export fidelity** (Word, Excel and the other exports): `pdf/tools/export-corpus` (see its README) after any change to
  `DocLayout`, `DocxWriter`, `PptxWriter`, `HtmlWriter`, `DocumentExport` or the glyph reading in `PdfEngine`.
- **Speed on huge files** (roadmap 3.6): `pdf/tools/bench` (`make`, `run`; see its README), also a release step.
- **Edited text in pdf.js**: `pdf/tools/pdfjs-check` (see its README; opt-in test `INKVOLTPDF_PDFJS`) after any change to
  `ContentEditor`.
