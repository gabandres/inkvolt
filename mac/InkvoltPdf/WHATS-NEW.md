# What's new in Inkvolt PDF for Mac

Shown in the app once after an update (Help › What's New any time) and used for the release notes of each download.
Each release gets a `## x.y.z` heading before it's made (`release.sh` warns when the version has none); `## Next`
collects what's done since the last release and is never shown. Short lines, in the user's words.

## Next
- Measure (Tools menu): click to measure a distance, a perimeter or an area on drawings and plans, with the value shown by the pointer as you go. Set Measuring Scale… ("1 in = 10 ft", this page or all) or Calibrate from a length you know saves the scale in the PDF, and the scales a drawing already has are used where they apply. Each measurement is a comment labeled with its value, written the way Acrobat and Inkvolt PDF for Windows write them, so it reads the same there.

## 1.3.0
- Compare Files… (File menu): pick the original and the changed version (an open document or any PDF) and see them side by side, page by page, with every inserted, removed and changed word marked on both sides and listed to step through. Text that only moved to the next page isn't a change; a removed or added page is one change. Visual overlays the pages (only in the original: red, only in the changed file: blue) for drawings and scans. Annotated Copy makes a copy of the changed file with every change as a comment, to save and share.
- Digital signatures: the Signatures pane in the sidebar (View › Show Signatures) checks every signature when you open a PDF and after each change: valid, changed after signing, changed in ways the signature doesn't allow, or invalid, with the signer, the time, the certificate and whether your Mac trusts it. Inkvolt PDF warns before an edit would invalidate a signature.
- Sign Digitally… (Tools menu, the Signature tool, or a click on an empty signature field): sign with a digital ID from your keychain (smart cards too), a .p12 file, or a personal ID made for you; drag where the signature goes, choose what it shows (your handwritten signature beside it, if you like), add a trusted timestamp or certify the document, then save the signed copy.
- Batch (File menu, and the start page): the same actions on many PDFs and pictures, saved to a folder with names from a template: reduce file size, protect or unprotect, sanitize, redact patterns, check redaction, report what's in each file, watermark, header and footer with Bates numbers, rotate, flatten, recognize text, export to Word, Excel, text, page images or form data. Save the list as a preset, export and import presets (the same files as on Windows), and watch folders: a file dropped in runs through a preset once it has finished copying.
- The command line: `InkvoltPdf --batch preset.json files…` and `--watch folder --preset preset.json` run a preset without a window, from a terminal or launchd (`--help` explains).
- Reduce File Size… (File menu): pictures downsampled to the chosen resolution, duplicates merged, streams compressed, unused objects dropped.
- Add Header & Footer… and Add Watermark… (Pages menu): page numbers, dates, Bates numbers, a text or a picture across the pages, written into them so they print everywhere; Remove takes them off again.
- Flatten… (Pages menu): comments and form fields become part of the pages.
- Help › Inkvolt Pro…: enter an Inkvolt Pro licence key, see whom it's licensed to, or remove it. Everything in Inkvolt PDF for Mac stays free while it launches, Pro features included; a licence ($19, one time, no account, checked on your Mac and never sent anywhere) supports the project and keeps those features for you when they start asking for a key. One key works on Windows and the Mac.

## 1.2.0
- What's in This PDF (Tools menu, and See What's in It… in Sanitize Document): one report of everything a PDF carries besides its pages: scripts and what they do, actions that run by themselves, every web address, file and program it can reach (marked when no click is needed), attachments, metadata and comment authors, signatures, earlier versions, hidden layers and text, form values and covers that hide nothing. It says what Sanitize removes, and saves as a web page or JSON. Nothing in the file is contacted.
- Edit Text & Images: clicking text on top of a picture edits the text.
- Redact by Pattern: a mistake in your own pattern is described in plain words.

## 1.1.0
- Redact: black out areas, selected text or every search match, or find Social Security, phone and card numbers, email addresses, dates, bank account numbers (IBAN), IP addresses, your own words or your own pattern, check the marks, then apply. What's under them is gone from the file, not just covered.
- Redaction check: after you apply redactions, Inkvolt PDF checks that nothing of what you redacted is left anywhere in the file and offers to fix what it finds. Tools › Check Redaction… checks any PDF for text still under black boxes or highlights, unapplied redaction marks and more.
- Sanitize Document (Tools menu): remove metadata, hidden layers, hidden comments and fields, scripts, links, attached files and earlier versions from a PDF before you share it.

## 1.0.0
- Read PDFs in tabs: smooth scrolling and zoom, thumbnails, the outline, find (match case, whole words), select and copy text, clickable links, full screen.
- Comments: highlight, underline, strike out, notes, text boxes, callouts, drawing (pen, highlighter, shapes, lines, arrows, polygons), stamps, pictures and links; replies, colors and a list of every comment.
- Forms: fill in text fields, check boxes, radio buttons and lists, with their calculations and formats; import and export form data.
- Fill & Sign: type anywhere, add check marks, dates and your signature or initials, drawn or typed.
- Edit Text & Images: change the words already on a page in their own font; move, replace or delete pictures.
- Recognize Text (OCR): make scanned pages searchable and their text copyable, with Apple's text recognition on your Mac.
- Export to Word, Excel or plain text.
- Organize pages: rotate, delete, duplicate, move, insert (from a PDF, pictures or blank pages), extract and crop; bookmarks.
- Combine files into one PDF, make a PDF from pictures or the clipboard, or scan pages straight into a new PDF (network scanners and USB scanners).
- Protect a PDF with a password, or remove its protection.
- Print with pages per sheet, booklets and posters.
- Undo and redo every change; saving keeps earlier signatures intact; recovery copies bring back unsaved work after a crash.
- A start page with the main tools, a command palette (⇧⌘K) that finds any command, and Settings (⌘,).
- Nothing you open leaves your Mac: no account, no tracking.
