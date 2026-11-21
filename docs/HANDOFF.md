# 2026-11-21: Inkvolt PDF 1.16.0.0 and Inkvolt Print 1.7.0.0 submitted (Windows roadmaps concluded)

Every Windows branch of 2026-11-19..21 is merged (the "not merged" entries below are on master now): Print scanners, PDF
test stability, Translate leftovers and pdf.js spaces in Arabic and Hebrew, the PDF editing backlog (real crop, Picture…),
Export links, Compare at another size or turn, folder search under 1 s, Print printer data, QR separator sheets, driver
lookups for Canon, HP, Brother and PFU, What's New in Spanish in both apps, the stale doc entries. Pre-release hostile-input
review of both diffs: two findings, fixed in c270fb77 (a WIA 2.0 page's stated size capped before WIC; the Tesseract download
gives up after a minute without a byte). Final `tools/test.ps1` on d81c8abe: Print 3103, PDF 3262 (two timing tests failed
under load and passed alone). Bench (`pdf/tools/bench/RESULTS.md`): every target met but `drawings.pdf` (the accepted limit)
and one `scan.pdf` page at 232 ms; folder search lists 500 pages of two common words in 0.77 s. Packed with the smoke test
(both passed), uploaded, release notes en and es through the API, committed and **Published** 2026-11-21; tags and GitHub
releases `pdf-v1.16.0.0`, `print-v1.7.0.0`; the website's `softwareVersion` is 1.16.0 and 1.7.0, deployed. Nothing left on
Windows but the owner's checks below.

**For the owner, hardware:** a WIA 2.0 scanner (page progress, Stop, a PDF-only WIA driver), a PC with only a 32-bit TWAIN
driver, a jam partway through a feeder scan; a printed QR separator sheet scanned for real; real installs through Get the
driver from Canon, HP, Brother and PFU (and PFU's licence page in the Store copy); the M234dw's IPP and SNMP page counts, its
panel text, SNMPv3 against it, a WSD printer that answers SNMP, a queue added in Settings appearing on the printer list; a
printer whose web page is on another port; a recording of a CDM printer's `/cdm/deviceUsage/v1/lifetimeCounters` would let
CDM lifetime counters be done. The M234dw has no LEDM walk-up scan, so HP's Scan to Computer can't be confirmed on it.
**For the owner, eyes:** Crop Picture's handles, the ￼ mark and Picture… (the editor stays open behind the file dialog);
links in an exported PowerPoint and in a browser; Compare's overlay on a real scan; Arabic and Japanese translated copies in
Firefox (copy a line, search a phrase) and Acrobat; Open Log Folder in both Store copies; a multi-file Explorer conversion
while the running copy doesn't answer; the Spanish of both apps' new What's New lines (PDF's older entries were translated
in one go). Exports in Office: done 2026-11-21. `pdf/tools/export-corpus` now has Excel open every .xlsx (read-only,
no window; a file Excel would repair fails to open, tried on three broken ones). 7 documents: Word's page counts are the
baseline's, PowerPoint and Excel open every file with every slide, shape, sheet and cell. LibreOffice is still optional (`-LibreOffice`, never run).
**Known limits, not action items:** `drawings.pdf` Find and scroll speed (MuPDFCore 2.0.1); pdf.js runs a right-to-left word
into a figure or Latin word beside it, and loses spaces on right-to-left lines with another look inside; MuPDF reads
Arabic-Indic digits backwards; Canon models sold only in the US or Europe aren't found and ScanSnap has no driver lookup;
the slow index runs are Windows Defender scanning each file (ROADMAP 3.5); the others in the 2026-11-19 entry.

# 2026-11-20: pdf.js reads the spaces in Arabic and Hebrew translations (Windows; branch worktree-agent-a89a2b9072fde6c80, not merged)

Translate writes a right-to-left line in stretches (`GlyphOrder.Stretches` in `Shaping.cs`, `pdf/ROADMAP.md` 3.1 "pdf.js
reads the spaces"): each right-to-left stretch left to right, the stretches and the figures and Latin words between them in
reading order. MuPDF reads it as before; pdf.js now reads the spaces between right-to-left words. After review, a version
inside Arabic ("2.0-beta") is drawn whole left to right, so MuPDF and Find read it (before, three lines). What one content
stream can't give both readers, now documented with the reason from their code: pdf.js runs a right-to-left word and a
figure or Latin word beside it together, and a line with a bold, other-font or raised word inside right-to-left text stays
in reading order (no spaces in pdf.js). Found, not changed: MuPDF reads Arabic-Indic digits backwards in any order.
**For a person:** an Arabic copy in Firefox (copy a line, search a phrase) and in Acrobat.

# 2026-11-20: Inkvolt Print's printer-data items closed (Windows; branch worktree-agent-a83f5e17d97d5cce9, not merged)

Seven commits, one an item (`print/README.md`, `print/ROADMAP.md` 1.1, 1.2, 3.2 and `print/WHATS-NEW.md` "Next" have each):
pages left and a cartridge's yield from CDM, IPP's `printer-supply` and the Printer MIB, and the page count from IPP's
`printer-impressions-completed` and `prtMarkerLifeCount` (`SupplyPagesTests`); recordings keep IPP collections and dateTime,
SNMP Counter64 and Opaque (`RecordingTests` +9); SNMPv3's MD5, SHA-1, DES, AES-192 and AES-256 beside each passphrase, the
short key lengthened Blumenthal's way then Reeder's (`SnmpV3ProtocolTests`); a web server on a port of its own, typed or from
`adminurl` (`PrinterWebPortTests`); the front panel's text under the status (`PanelTextTests`); SNMP for WSD queues from the
WSD node's PnP-X address (`WsdSnmpTests`); queue change notices from the spooler (`QueueChangeTests`, `queues --watch`).

**Only a real printer confirms:** a printer's own `printer-supply` in impressions and its `printer-impressions-completed`; a
Printer MIB supply counted in impressions and a real `prtMarkerLifeCount`; a recording of a printer with `media-col-database`;
SNMPv3 on a printer's agent with each protocol, and which key extension a maker's agent uses for AES-192/256 after MD5 or SHA-1
(both are tried); a printer whose web server is on another port, and whether its `adminurl` says so; what a real panel's lines
hold; a WSD printer that answers SNMP (the PnP-X address was read here for one of the two WSD printers, which was away). The
app's printer list following a queue added in Settings was checked through `queues --watch` (add, rename, remove: one notice
each), not on screen. **Review (10 findings) fixed in one commit:** WSD queues through one rule for the app, the Fleet page and
`status --all` (`QueueSources`: SNMP only while the WSD node is present, only once the device says it is this printer by PnP-X's
serial number or model, a new address a new source, the driver's levels and their caption kept when SNMP is silent); a web
root kept only where LEDM or CDM answered and let go when they stop, never port 631 or `/ipp/`; the spooler asked for
everything again after dropped notices; the page count and panel walks can fail alone; the watcher's stop event left to its
thread; a ready printer's one-line panel state in any language hidden. **CDM lifetime counters: not done** (no reply of
`/cdm/deviceUsage/v1/lifetimeCounters` in the repository and no published HP schema; a recording of a CDM printer is what makes
it possible). **Mac follow-up:** PrintCore has none of these (the .NET code is its spec; SNMPv3's other protocols need
`SnmpCrypto` to give MD5, SHA-1, DES and longer AES keys).

# 2026-11-20: Translate's leftovers closed (Windows; branch worktree-agent-a11e03ded4fac60e7, not merged)

Six commits and a review-fix commit, `pdf/ROADMAP.md` 3.1 has each: plain underlines as a look (`<u>`, the rule redrawn
under the translation); looks in right-to-left text; up to three other looks a paragraph (`<span>`, `<font>`, `<mark>`);
scripts longer than 12 characters; pdf.js reads a copy (`TranslationPdfJsTests`, opt-in); a real model in five languages.
**Real model run** (Qwen3 4B Instruct 2507 Q4_0 on our own llama-server, port 8123, never the knowledge base's 8091): NIST
p. 1, attn-v7 p. 3, fw9 p. 1 into Spanish, French, German, Arabic, Japanese, 30-155 s a page; every answer's words in every
copy; tags kept whole in 11/11/12/5/6 of 16 marked texts (es/fr/de/ar/ja). Fixed from it: the prompt names only the tags a
text has (a model told of `<font>` wrote `<font color=…>`), `<bold>`/`<strong>`/`<em>` read as ours, words a model put in
angle brackets kept, a ligature's letters in a right-to-left run drawn left to right read in order, and (after review)
two Arabic values on NIST p. 1 MuPDF read backwards: Calibri's Arabic lowers joined letters and MuPDF reads such lines
backwards, so right-to-left lines take the closest font whose letters stay on the line (Segoe UI there). Review's 10
findings fixed. pdf.js read right-to-left lines without their spaces (written left to right for it, MuPDF read figures
and brackets backwards); closed in the entry above. For a person: a translated Arabic and Japanese copy on screen and in Acrobat; Make
Text Editable on an Arabic scan (the editor now reads right-to-left text drawn left to right in reading order).
# 2026-11-19: concluding the roadmaps on Windows (owner: "do all for Windows"; Mac halves wait for a new Mac)

**Merged and pushed** (each reviewed with `/code-review` high, all findings fixed, `tools/test.ps1` green in its worktree):
Print 3.3 the printer's own copier and copy extras (`085f2d19`), Print 2.1 printing straight to the printer over IPP
(`7da5da4c`), PDF 3.6 speed (`31f84311`), Print 2.2 scan from the printer's button (`a0284f75`), PDF 2.2 part A Tesseract
as an optional download and two-language pages (`0ae83a72`), Print 3.1 scanner sharing over eSCL with Kestrel
(`daf71fcb`), PDF 3.1 Translate's Still wrong list (`464121f2`). Not released: the next Store versions carry them.

**Left (start here after the owner's reboot):** PDF 2.2 part B (straightened lines, trapezoid correction, "make the text
editable"); PDF 1.2's checks (a 500-file Batch over a network share on this PC, `--batch`/`--watch` through the installed
package's alias). Then a full `tools/test.ps1` on master, the bench, and a release when the owner says. Owner, 2026-11-19:
continue past the usage gate's 60 % this week. Leftover locked worktrees under `.claude/worktrees` (merged): remove.

**Needs the owner or hardware:** Record a printer on the M234dw (copy element names; it has no LEDM Scan to Computer), a
copy and a direct IPP print on it, scanner sharing from an iPhone or a Mac on a Private network with a real USB scanner,
Tesseract's language list and download wording, comments.pdf's panes filling ~1 s after the pages, translated scripts on
screen.

# 2026-11-17: Windows catches up with the Mac (no Mac from now on)

**Owner, 2026-11-17: no Mac any more; all work is Windows.** Mac items in this file wait indefinitely. The three Mac-first
features Windows lacked are ported and merged (not released): Inkvolt Print's SNMP access… check and refused state
(`f29e3ed9`), Inkvolt PDF's moving and recoloring of notes and text marks, and its Polygon and Polyline tools (`820e75b0`);
each reviewed with `/code-review` medium, all findings fixed. Also `441f2a66`: the build on .NET SDK 11.0.100 (IppPrintDevice
gated at build 22621), and `tools/test.ps1` now fails an aborted run (a crashed test host once left ~530 PDF tests unrun
and passed). Master's `tools/test.ps1` on SDK 11: Print 2,482, PDF 2,942, 0 warnings; flaky under load:
`PageCheckTests.APageTheLimitRefusedDrawnSmoothIsRefusedStill`. The test host crash and the hang (2026-11-20): not reproduced in 6 PDF runs
with --blame-crash/--blame-hang under load (beside Print, two PDF suites at once, other agents' runs); MuPDF's "premature
end of data in flate filter" is printed by many tests, not by a crash. What load did do: a starved thread pool stalled every
worker pipe (WorkerPipe now, see Tests below), the likeliest cause of the hang; a crash seen meanwhile was a new test's own
(fixed before commit). If the host crashes again: the blame dump and the last tests in the TRX. For a person: the new tool icons, dragging marks in a turned view, the Comments pane's Color menu, the SNMP
dialog with Narrator, a refused SNMPv3 printer (the demo has none).

**Released (owner's go, 2026-11-17): Inkvolt PDF 1.15.0.0 and Inkvolt Print 1.6.0.0 submitted to the Store**, both packed
from `a162009b` (tags `pdf-v1.15.0.0`, `print-v1.6.0.0`, GitHub releases, PDF marked Latest). Before it: a hostile-input
review of each app's changes since its last release (PDF 5 findings, Print 3, all fixed: `659d6d5c`, `1b96ca76`), the
bench (`8a40bcf8`; scan.pdf's on-screen 48 fps is this PC's load: 1.14.0.0 measured the same then), smoke side by side
for both. PDF submission 1152921505702431116, Print 1152921505702430623; release notes en and es through the API.
**Published** in the Store (both, seen 2026-11-19); the website's `softwareVersion` updated (1.15.0, 1.6.0) and deployed.

# Older entries

`docs/handoff/ARCHIVE.md`, newest first, from 2026-11-06 back to 2026-10-30: the Mac machines (the M6 mini replacing the
M1 Air, the keys backed up to OneDrive and what to restore), the Mac backlog (Office as E12's converter on the Mac), the
plans and owner's briefs of 2026-11-05 to 2026-11-08, earlier releases.
