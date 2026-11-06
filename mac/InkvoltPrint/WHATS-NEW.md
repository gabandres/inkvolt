# What's new in Inkvolt Print for Mac

The App Store's "What's New in This Version" for each update is made from these notes (`assets/store/listing.json`'s
`whatsNew`, which `asc-listing.mjs apply` sends). Each release gets a `## x.y` heading before it's submitted; `## Next`
collects what's done since the last release. Short lines, in the user's words.

## Next
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

1.0 and 1.1 (build 5, live 2026-11-06) had their notes in `listing.json` only.
