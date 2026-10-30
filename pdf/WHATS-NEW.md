# What's new in Inkvolt PDF

Shown in the app once after an update (Help › What's New any time) and used for the Store's "What's new in this version".
Each release gets a `## x.y.z` heading before it's packed (`packaging/pack-msix.ps1` warns when the version has none);
`## Next` collects what's done since the last release and is never shown. Short lines, in the user's words.

## Next
- Help › Inkvolt Pro…: enter an Inkvolt Pro licence key, see whom it's licensed to, or remove it. Everything in Inkvolt PDF stays free while it launches, Pro features included; a licence ($19, one time, no account, checked on your PC and never sent anywhere) supports the project and keeps those features for you when they start asking for a key.

## 1.2.1
- Once you've saved a few documents with Inkvolt PDF over at least two days, it asks one time whether you'd like to rate it in the Microsoft Store, in the Store's own window. It never asks again, whatever you choose.

## 1.2.0
- Edit Text & Images: click text to edit its whole paragraph. What you type rewraps in the paragraph's box with its alignment and line spacing, and you're asked first when it would run into what follows.
- Paragraph editing: characters the PDF's copy of a font doesn't have (an embedded font usually holds only the letters the document used) are now drawn from the closest font on your PC, named under the editor; the rest of the paragraph stays in its own font.
- Paragraph editing: give part of a paragraph another font, size, color, bold or italic from the bar above the editor. Edit the paragraph again later and those looks are still there.
- Paragraph editing is more careful: right-to-left paragraphs and paragraphs with a footnote mark or symbol inside them are edited line by line, and spaces drawn on their own go with the text they belonged to.
- What's in This PDF (Review menu, also in Document Properties and Sanitize): one report of everything a PDF carries besides its pages and what it does when opened: scripts and what they call, every web address, file and program it can reach (marked when no click is needed), attached files, authors and other metadata, signatures, earlier versions and what they still show, hidden layers and text, form values. Save it as a web page or JSON. Nothing in the file is contacted. Also a Batch action.

## 1.1.0
- Update check: when a new version is ready in the Microsoft Store, an Update button appears at the top of the window (Help › Check for Updates… looks now). You can turn it off in Settings.
- Accessibility check (Review › Accessibility Check…): checks a PDF against PDF/UA, the standard for PDFs people with screen readers can use, on your PC. Each problem says what is wrong, where (click it to see it on the page) and how to fix it; a checklist covers what only a person can judge, such as reading order and whether image descriptions make sense. Save the report as a web page. Also a Batch action, with a report beside each file.
- Comments in and out (Review menu): export all comments as XFDF or FDF for Acrobat and other PDF apps, or as a CSV for a spreadsheet, with replies, colors, authors, dates and stamp and drawing appearances; import them into another copy without duplicating the ones already there. Summarize Comments makes a PDF with each page beside its comments, numbered and connected.
- Form data in and out (Edit › Forms): export a form's values as XFDF, FDF, CSV or JSON and fill a form from any of them. Fill Forms from CSV fills one copy of the form per row of a spreadsheet and lists the rows it couldn't fill and why. Also in Batch, and from a terminal: inkvoltpdf --fill.
- Batch presets: save the list of Batch actions under a name and pick it next time; export a preset to share it, import one from someone else (a plain JSON file). New Batch action: Save as PDF/A.
- Watched folders (Batch › Watched Folders…): drop PDFs or images into a folder and Inkvolt PDF runs a preset on each one once it has finished copying, then moves the original to "done" or "failed" and logs a line for it.
- Command line: inkvoltpdf --batch runs a preset on files or folders without a window, and inkvoltpdf --watch watches a folder from a terminal or a scheduled task (inkvoltpdf --help).
- Redaction check: after you apply redactions, Inkvolt PDF checks that nothing of what you redacted is left anywhere in the file (other pages, comments, form fields, bookmarks, properties, attached files, hidden layers, earlier versions) and offers to fix what it finds. Review › Check Redaction… checks any PDF for text still under black boxes or highlights, unapplied redaction marks and more. Also a Batch action.
- Redact by Pattern (Review menu): find and mark Social Security, phone and card numbers, email addresses, dates, bank account numbers (IBAN), IP addresses, your own words or your own pattern, on all pages or some; check the marks, then apply. Also a Batch action for many files at once.

## 1.0.8
- Steadier: a few specially made PDFs could hang or close Inkvolt PDF (when deleting pages, reducing size, sanitizing, redacting or filling a form); they no longer do.
- Closing never drops changes made while it asks about another document, and recovery copies are kept when a restore or a write fails.
- Remove Protection works on files that only have restrictions (no open password).

## 1.0.7
- Tools on the start page: Fill & sign, Edit, Export to Word, Combine, Compare, Reduce size, Protect, Redact, OCR, Organize, Batch and Create a PDF, one click each (pick a PDF and it opens straight in the tool).
- Organize pages has a bar with the page actions: rotate, delete, duplicate, extract, move, insert, crop.

## 1.0.6
- Recovery copies: if Inkvolt PDF closes unexpectedly (a crash, a power cut), the next start offers your unsaved changes back.
- Tabs: right-click a tab for Close Others, Close Tabs to the Right, Copy Path, Show in Folder and Reopen Closed Tab; tabs with the same name show which file is which.
- Settings › Reset to defaults.
- Help › What's New, and Help › Report a Problem: copies the details a report needs, with file paths and your names masked, to paste into a GitHub issue. Nothing is sent by the app.
## 1.0.5
- Steadier editing: every page change, form edit and signature goes through one tested path that keeps a protected file protected and a signed file's signatures, with the same undo history.
- Export to Word, Excel and text uses one tested path, the same for single files and Batch.

## 1.0.3
- Edit text and images right on the page.
- Prepare Form: create text fields, check boxes, radio buttons, lists, signature fields and buttons, or detect fields on a page automatically.
- Compare two versions of a PDF, text and visual.
- Export to Word, Excel or plain text, with text recognition for scanned pages. Forms keep their layout in Word: fill-in lines, labels and boxes where they were.
- Make PDFs from Office files (with your installed Microsoft Office) and from web pages.
- Save as PDF/A-2b for archiving.
- Measure distances, perimeters and areas, with a drawing scale or calibration.
- Batch: run the same actions on many files at once.
- Split view: two places of the same document side by side.
- Sanitize Document: remove hidden data such as metadata, scripts, hidden layers and attachments.
- Headers and footers (with Bates numbers), watermarks, stamps, pictures and links.
- Print preview in the Windows print dialog, with page sizing (actual size or fit to paper) right there.
- Print with Options: pages per sheet, booklet and poster.
- Optional AI assistant, bring your own (off by default): summarize, ask about a document or explain a passage with Ollama, LM Studio or a service you choose. Answers are AI-generated and may be wrong. You see exactly what is sent, and where, before anything goes.
- Filled forms look the same in every viewer, new icons, and many fixes.
- Fixed: opening files failed on PCs without the Visual C++ runtime.
