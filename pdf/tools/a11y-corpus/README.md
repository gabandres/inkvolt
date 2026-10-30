# Accessibility corpus

Unit tests check each Matterhorn condition on PDFs built by hand. They can't tell you whether the checker agrees with a
real validator on files that Word, InDesign or LaTeX wrote. This tool runs Inkvolt PDF's checker (`AccessibilityCheck`)
over 50 public PDFs and compares each result with veraPDF's PDF/UA-1 validation: pass or fail per file, and which
conditions fail (veraPDF's rules mapped to Matterhorn numbers, `VeraGroup` in `Program.cs`).

```powershell
pwsh -File pdf/tools/a11y-corpus/run.ps1               # download what's missing, run veraPDF, compare
pwsh -File pdf/tools/a11y-corpus/run.ps1 -Synthetic    # also veraPDF's own PDF/UA-1 test files (297 small ones)
pwsh -File pdf/tools/a11y-corpus/run.ps1 -Install      # install veraPDF unattended into C:\Tools\verapdf first
```

Run it after changing `AccessibilityCheck*.cs`, `TextFonts.cs`, `FontPrograms.cs` or `HybridXref.cs`; with `-Tag` after
changing `AutoTag*.cs` or `DocLayout.cs`.

**veraPDF is for testing only and never ships.** It needs Java 8 or later (`winget install Microsoft.OpenJDK.21`);
`-Install` fetches the installer from software.verapdf.org and installs it without questions. The PDFs go to
`C:\Temp\a11y-corpus` (`-Corpus`), outside the repo, and none is committed: `corpus.json` keeps each one's address and
SHA-256, and says when a publisher replaced one.

**The corpus** (`corpus.json`): the PDF Association's PDF/UA Reference Suite 1.1 (9 files: InDesign, Photoshop, PDFlib,
LaTeX, remediated documents) and its "PDF/UA in a Nutshell"; real-world documents from veraPDF's regression set (Word
2016 and Microsoft 365, Acrobat PDFMaker for Word, InDesign, deskPDF, madbuild, QuarkXPress via Distiller, OpenOffice,
iText); arXiv papers, tagged (LuaTeX) and untagged (pdfTeX); IRS form W-9, a NIST standard and a USGS fact sheet; and 14
of veraPDF's own PDF/UA-1 test files (one pass and one fail for headings, tables, figures, tab order, fonts, notes).
14 pass veraPDF, 36 fail.

**Result (2026-10-27, veraPDF 1.30.3):** the same pass or fail for 50 of 50 files; the same failing conditions for 49 of 50.
With `-Synthetic`: 296 of 297 files (the other can't be opened, below), conditions the same for 296.

## Make Accessible on the corpus

`run.ps1 -Tag` also runs Make Accessible (`AutoTag`) and checks what it writes: the untagged files as they are (into
`C:\Temp\a11y-tagged\untagged`), and 12 Word and office files with their own tags replaced (`...\retagged`), as an
untagged export of theirs would be tagged; each figure gets a stand-in alternate text, as a person would type one.
veraPDF validates both folders and the comparison runs as above. `tag [--all] <out> <pdf>…` and `pdfa <out> <pdf>…`
(Save as PDF/A-2a, for `verapdf -f 2a`) do the steps one at a time.

**Result (2026-10-30, veraPDF 1.30.3, branch `pdf-accessible-2`):** the 2 untagged files (pdfTeX papers) pass PDF/UA-1
in the checker and in veraPDF: Make Accessible now gives the TeX math fonts' glyphs their Unicode (`FontUnicode`; they
failed 31-027 / 7.21.7-1 before). Of the 12 re-tagged files, 5 pass veraPDF PDF/UA-1; the other 7 fail only on
form-field tooltips (28-005) or fonts (31-009, 31-014, 31-030), which tagging doesn't change. Same pass/fail and
conditions as the checker for 14 of 14. Saved as PDF/A-2a (`pdfa`), 10 of the 14 are made and all 10 pass veraPDF 2a
and ua1 (both papers, the NIST standard, the Word files); 4 are refused (a signature, CMYK without a profile twice, a
Times that would move).

## Known differences

- **wcag-table-word.pdf, 15-003 (ours only).** The table's header cells have no Scope and its data cells name no headers
  (Headers), which is exactly what Matterhorn 15-003 fails, and what veraPDF fails in pdfua-nutshell.pdf and
  rw-table-with-attributes.pdf. veraPDF's PDF/UA-1 rule (GFSETable) gives the same answer for this table's structure,
  yet passes this one file: a veraPDF inconsistency, not a different rule. Both fail the file (it lacks the PDF/UA
  identifier), so the file-level result matches.
- **7.5-t01-fail-c.pdf (synthetic).** Its content lives in an external file stream (`/F` in a stream dictionary), which
  PDFsharp can't read: the check reports that the file can't be checked.
- veraPDF reports a CMap that another CMap uses (`/UseCMap`) under its CMap rule (7.21.3.3-1) as well as the referenced-CMap
  rule; we report it once, as 31-008. The comparison counts 31-006 and 31-008 together for that reason.

## What veraPDF taught the checker

Each was found by this comparison and fixed (with a unit test where a hand-built file can show it): Word's
hybrid-reference files keep the structure tree where PDFsharp doesn't look (`HybridXref`); tags the structure tree's root
doesn't lead to tag nothing; an artifact inside tagged content fails both 01-003 and 01-004; a standard type mapped to
itself is a circular mapping; indirect /Lang and DisplayDocTitle values; TrueType glyph lookup through a Mac (1,0) cmap
by glyph name and through Unicode-platform cmaps; CIDSet must match the font program exactly (subset TrueType fonts that
keep empty glyph slots count them); CharSet both ways; a symbolic font's own encoding; a field's tooltip is the field's,
not its widget's; a pop-up note isn't read on its own; the struct parent's own /Lang (not its ancestors') for comments
and fields; XFA's `dynamicRender` with whitespace in its closing tag; a media clip's Alt pairs.

## Commands

`dotnet pdf/tools/a11y-corpus/bin/Release/net10.0/win-arm64/A11yCorpus.dll` with `check <pdf>…` (pass or fail and the
conditions), `show <pdf>` (every finding), `html <pdf> <out.html>` (the report), `compare <verapdf.xml> <folder> [out.csv]`,
and for looking inside a file: `tags <pdf> [type]` (the structure tree with attributes), `obj <pdf> <n|root>`, `find <pdf> <text>`,
`glyphs <pdf>` (each simple font's codes without Unicode and their glyph names).
