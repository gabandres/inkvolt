# Handoff

What a next session needs: where things stand, what's open, what waits. Older entries are in git history;
the Mac machines and where the keys are backed up: `mac/docs/NEW-MAC.md`; what the Mac still lacks: `mac/docs/PLAN.md`, "Open".

## Current state

- **Released:** Inkvolt PDF 1.16.0.0 and Inkvolt Print 1.7.0.0, Published in the Microsoft Store 2026-11-21 (tags and
  GitHub releases `pdf-v1.16.0.0`, `print-v1.7.0.0`; the website's `softwareVersion` 1.16.0 and 1.7.0). The next
  submission of each must be higher.
- **Windows roadmaps:** Waves 1-3 of `pdf/ROADMAP.md` and `print/ROADMAP.md` are built and merged. **Wave 4** (a market
  check, 2026-11-21; the owner: do all of it and release it) is under way in its batches, each released to the Store as
  it is merged and reviewed: PDF 1.17.0.0 and Print 1.8.0.0 carry Batch A (and B if it is ready).
- **The Mac waits** (owner, 2026-11-17: no Mac any more; all work is Windows). Every Mac half in both roadmaps waits for
  a new Mac, indefinitely; setting one up: `mac/docs/NEW-MAC.md`. PrintCore has none of Inkvolt Print's printer-data work
  of 2026-11-20 (pages left and yield from CDM, IPP and the Printer MIB; recordings keeping IPP collections and SNMP
  Counter64/Opaque; SNMPv3's other protocols, which need `SnmpCrypto` to give MD5, SHA-1, DES and longer AES keys; the
  web server on its own port; the panel text; SNMP for WSD queues; queue change notices): the .NET code is its spec.

## For the owner: hardware

- Scanners: a WIA 2.0 scanner (page progress, Stop, a PDF-only WIA driver); a PC with only a 32-bit TWAIN driver; a jam
  partway through a feeder scan; a printed QR separator sheet scanned for real; scanner sharing from an iPhone or a Mac on
  a Private network with a real USB scanner behind it.
- Get the driver: real installs through the app from Canon, HP, Brother and PFU (and PFU's licence page in the Store
  copy).
- The M234dw: Record a printer on it (the copy documents' element names; it has no LEDM walk-up scan, so HP's Scan to
  Computer can't be confirmed on it); a copy on the printer and a direct IPP print; its IPP and SNMP page counts, its panel
  text, SNMPv3 against it.
- Other printers: a WSD printer that answers SNMP; a queue added in Settings appearing on the printer list (checked only
  through `inkvoltprint queues --watch`); a printer whose web page is on another port; a recording of a CDM printer's
  `/cdm/deviceUsage/v1/lifetimeCounters` (what makes CDM lifetime counters possible); a refused SNMPv3 printer (the demo
  has none).

## For the owner: eyes

- Inkvolt PDF: Crop Picture's handles, the ￼ mark and Picture… (the editor stays open behind the file dialog); links in
  an exported PowerPoint and in a browser; Compare's overlay on a real scan; Arabic and Japanese translated copies in
  Firefox (copy a line, search a phrase) and Acrobat; Make Text Editable on an Arabic scan; Tesseract's language list and
  download wording; comments.pdf's panes filling about 1 s after the pages; the tool icons, dragging marks in a turned
  view, the Comments pane's Color menu.
- Inkvolt Print: the SNMP access dialog with Narrator.
- Both: Open Log Folder in both Store copies; a multi-file Explorer conversion while the running copy doesn't answer; the
  Spanish of both apps' newer What's New lines.
- `pdf/tools/export-corpus` with `-LibreOffice` (optional; never run).

## Known limits (not action items)

`drawings.pdf` Find and scroll speed (MuPDFCore 2.0.1); pdf.js runs a right-to-left word into a figure or Latin word
beside it, and loses spaces on right-to-left lines with another look inside; MuPDF reads Arabic-Indic digits backwards;
Canon models sold only in the US or Europe aren't found and ScanSnap has no driver lookup; the slow index runs are Windows
Defender scanning each file (`pdf/ROADMAP.md` 3.5).

## If the test host crashes or hangs

Not reproduced under load with `--blame-crash`/`--blame-hang`; MuPDF's "premature end of data in flate filter" is printed
by many tests, not by a crash. A starved thread pool stalling the worker pipes was the likeliest cause of the hang
(`WorkerPipe`). If it happens again: the blame dump and the last tests in the TRX.
