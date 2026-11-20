# Tesseract pins

Inkvolt PDF downloads Tesseract only when someone chooses a language Windows can't read (roadmap 2.2), and keeps only
files it knows: `pdf/src/InkvoltPdf.Core/TesseractCatalog.cs` pins the installer (address, size, SHA-256), the place,
size and SHA-256 of each file taken out of it, and each language file of tessdata_fast. This script writes that file.

```powershell
python -I pdf/tools/tesseract-pin/pin.py C:\some\empty\folder
python -I pdf/tools/tesseract-pin/pin.py C:\some\empty\folder --installer <url> <sha256> --tessdata <commit>
```

The folder receives the downloads (the installer, about 27 MB, and the 113 language files, about 340 MB). Without
arguments it pins what the catalog pins now; to move to a new release, pass the installer's address from
`tesseract-ocr/tesseract`'s GitHub release and the SHA-256 GitHub shows for it, and a `tessdata_fast` commit.

What it does: checks the installer's SHA-256, decodes its NSIS solid LZMA stream (Python's `lzma`), reads the NSIS
header for the files installed in `$INSTDIR`, follows tesseract.exe's import table through the DLLs it loads, and pins
those, plus `doc\LICENSE`. The app never runs the installer: it decodes the same stream (`Lzma.cs`) and keeps those
files only.

After pinning: `pwsh -NoProfile -File tools/test.ps1` (`TesseractTests.ThePinsAreWellFormed`), then the real engine
once, `INKVOLTPDF_TESSERACT=download` with `dotnet test pdf/tests/InkvoltPdf.Tests --filter RealTesseractReadsAPage`,
which downloads, extracts and checks it as the app does and reads a page.
