# What's new in Inkvolt Print for Mac

The App Store's "What's New in This Version" for each update is made from these notes (`assets/store/listing.json`'s
`whatsNew`, which `asc-listing.mjs apply` sends). Each release gets a `## x.y` heading before it's submitted; `## Next`
collects what's done since the last release. Short lines, in the user's words. `WHATS-NEW.es.md` is their Spanish, line
for line, for the es-MX listing (`listing.json`'s `localizations`): an English line needs its Spanish there (`PdfStringsTests`).

## Next
- Both sides on a feeder that scans one side: turn on Both sides: turn the stack over (or the scan preset's option), scan the fronts, turn the stack over when asked, and the backs go in page order. Backs in the Other Order is one click for a scanner whose tray reverses the stack, and Undo puts them back.
- Pages turned upright on their own: a page fed upside down or lying sideways is turned when its text shows clearly which way is up, and says Turned upright. Undo turns them back; Turn pages upright in Scan settings and in each scan preset turns it off.
- Smaller file (black and white) in a scan preset: its PDF's pages are saved in black and white, so a page of text takes a tenth of the space or less.
- Clean up drops a color and removes punch holes: a red form's lines, a blue pen's notes or a stamp turn white while the black print stays (red, green, blue, or a color you pick off the page), and the round shadows of punch holes near the edges take the paper's color. In Scan settings, each scan preset, and Clean Up… on a page.
- Join two halves: for an original too big for the glass, scan one half, then the other with an inch or so of overlap, and choose Join with the Next Page… on the first. Inkvolt Print finds where they overlap (either way up, on any side) and shows the joined page; when it isn't sure, move the second half with the arrows. Undo splits them again.
- A scan named from its first page: {text-date}, {text-title} and {text-number} in a scan preset's file name take a date, the heading and an invoice or order number from the page's text. With Stop on the pages to review them before saving, the name shows beside Save, to change before saving.
- Scan straight to Word or text: a scan preset saves the text read from the pages as a Word document (.docx), headings and paragraphs ready to edit and photos as pictures, or as a plain text file (.txt).
- Recent Scans… in the Scan tab lists the last 20 scans saved on this Mac, from every scanner: open one, show it in Finder, email it again, print it again or remove it from the list. Files deleted or moved drop out by themselves.
- Print the Clipboard (⇧⌘V, in the Print menu): copied text is laid out on pages and printed, a copied picture opens in Print Photos, and PDFs and pictures copied in Finder print as they are.
- Both sides by hand on a printer that prints one side: Print a PDF on Both Sides by Hand… and Batch Print's Two-sided print the fronts, show how to put the stack back (printed side down or up, an odd last sheet set aside), then print the backs in the order the stack feeds them.
- Cards, calendars and collages in Print Photos: a folded card (two to a sheet, the photo on the front, your message inside), a month or year calendar under each photo in the app's language, and a collage of 2 to 9 photos in rows, columns or one large. Save as PDF… saves any layout as it prints.

## 1.3.1
- A scan named COM0 or LPT0 gets an underscore, like the other names Windows keeps for its devices, so it opens on a PC too.

## 1.3
- Inkvolt Print speaks Spanish: the whole app, its alerts and messages follow the language you choose for it in macOS (System Settings › General › Language & Region › Applications) or in Settings › Language.
- SNMP access: a printer that answers only SNMP and whose administrator changed its read community can be added with that community (Add a Printer › Know its address? › SNMP access) and changed later (SNMP Access… in the printer's menu in the sidebar). It's kept in your keychain and used only to read the printer.
- SNMPv3: the same SNMP access fields take a printer's SNMPv3 user and its two passphrases (SHA-256 authentication, AES-128 privacy). Every request is signed and encrypted, only reads, and a wrong user name or passphrase is named (an Inkvolt Pro feature, free for now).
- A damaged PDF from a scanner no longer stops or freezes Inkvolt Print, and a very long ink and toner history opens quickly.
- A scanned page too large to edit (over 300 million pixels) is saved just as the scanner sent it, and its note says it wasn't straightened, cropped or turned, instead of filling your Mac's memory.

## 1.2
- Scan clean up (Scan settings › Clean up, and in each preset): crop to the paper, whiten the background, descreen printed pictures, restore faded colors. Clean Up… on a page shows it large to try each one, Show as scanned to compare, and All Pages; Undo puts a clean up back.
- Searchable PDFs keep text in every language your Mac reads, Russian, Arabic, Chinese, Japanese and Korean included, so Preview and other PDF apps find it; choose the Text language for a scan or a preset.
- USB printers that print without a driver (IPP over USB) show their own ink or toner levels and status, read from the printer itself; the status card says where its status came from, and a printer that reports no levels says so.
- Job notifications (Settings › Alerts, off until you turn them on): when your own print job fails or stops moving, a notification names the document and the printer, with Open the Queue and Pause Alerts. Other people's jobs never raise one.
- Ink and toner history: Inkvolt Print keeps a reading a day on your Mac and shows a chart of the levels over the last year, about how many days each cartridge has left, and how many pages you've printed since it went in. Low-ink alerts say how many days are left too. Export history… saves it all as one spreadsheet file (an Inkvolt Pro feature, free for now).
- Firmware watch: when a printer's firmware changes, its status card says so. HP printers: Keep My Cartridges Working, in the Settings tab, turns automatic firmware updates off, so an update that blocks non-HP cartridges can't install by itself.
- Scanners that send only PDF work, and a scan saved untouched is kept exactly as the scanner sent it.
- Help › Inkvolt Pro…: enter an Inkvolt Pro key; Inkvolt PDF on this Mac finds it too.
- Inkvolt PDF on this Mac shows the status and toner of your printers here when you print, and warns before printing to one that's off or jammed.
- Help › Report a Problem…: the details a bug report needs, with addresses, serial numbers and your names masked, to copy into a GitHub issue. Record This Printer saves what the printer shown answers, read only and with what identifies it taken out, as a .zip to attach. Nothing is sent.
- Fleet, at the top of the sidebar (View › Fleet): every printer on one page, the ones in trouble first, with each one's ink or toner, page count, firmware and when it was last read; a printer that isn't answering shows what it last said. Export… saves the list as a spreadsheet or JSON, and Fix All resumes paused printers and lets them accept jobs again, asking before each one (Inkvolt Pro features, free for now). From Terminal, `Inkvolt Print status --all --json` lists every printer for a script.
- Batch Print (File › Batch Print…): add PDFs and pictures, or a whole folder, put them in order and see how many sheets each one takes before anything prints. Print sends them to the printer one by one, asks first when a batch comes to more than 100 sheets, and Stop stops between files; a file that changed or needs a password is never printed by surprise. Save a list to print again, print a folder as files land in it, save the results as a spreadsheet, and print a list from Terminal with `Inkvolt Print print --list` (Inkvolt Pro features, free for now).
- Open in Inkvolt PDF, when it's installed on this Mac: a scan preset can open its PDFs there, Settings › General's Open scans in Inkvolt PDF opens each saved scan, and the save bar offers it after a PDF is saved.

1.0 and 1.1 (build 5, live 2026-11-06) had their notes in `listing.json` only.
