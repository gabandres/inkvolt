# What's new in Inkvolt Print

Shown in the app once after an update (Help › What's new any time) and used for the Store's "What's new in this version".
Each release gets a `## x.y.z` heading before it's packed (`packaging/pack-msix.ps1` warns when the version has none);
`## Next` collects what's done since the last release and is never shown. Short lines, in the user's words.

## Next
- Clean up can drop a color: a red form's rules, a blue pen's notes or a stamp turn white, and the black print stays. Pick red, green or blue, or click the color on the page. Remove punch holes fills the round hole marks near the edges with the paper's color. Both work per scan, per preset and per page.
- Name a scan from what it says: a preset's file name can use {text-date}, {text-title} and {text-number}, a date, the heading and an invoice or order number read on the first page. With the review step, the name shows before you save, to change if you like.
- Join two halves: for an original too big for the glass, scan one half, then the other with a little overlap, and choose Join with the next page… on the first. The overlap is found and the halves become one page; if it can't be found, move the second half into place with the arrows.

## 1.8.0
- Both sides on a feeder that scans one side: check Both sides: turn the stack over (or the preset option), scan the fronts, turn the stack over when asked and scan the backs. The pages come out in order; if your scanner's tray reverses the stack, Backs in the other order fixes it, and the review says when the fronts and backs don't match up.
- Pages fed sideways or upside down are turned upright on their own when their text shows which way is up (Turn pages upright, on by default, also per preset). Pages it isn't sure of stay as they came, and Undo turns them back.
- Smaller PDFs: a preset's new Smaller file (black and white) choice saves each page in black and white, often a tenth of the size or less. Scans in black and white are saved that way too.
- Sharing a scanner on the network is now free for good, not part of Inkvolt Pro.
- Ready for Windows' new printer driver: About this printer says which driver Windows uses for it, whether the printer works with Windows' own driver and its protected print mode, and Set up with Windows' driver adds it again that way beside your old one. A scanner that only works through its Windows driver is flagged, as it won't scan in protected print mode.
- Both sides on a printer that prints one side: Print a PDF, Batch and Copy offer Print on both sides by hand. The fronts print, then the app shows how to put the stack back for your printer (it asks which way up the sheets came out) and prints the backs.
- Print the clipboard: in the Print tab, Print the clipboard prints text you copied (laid out on pages, with the usual options), a copied picture through Photos, or files you copied in File Explorer.
- Recent scans: the Scan tab's Recent scans… lists your last saved scans from every scanner, to open, show in their folder, email again or print. The list stays on this PC.

## 1.7.0
- Print to a network printer that isn't set up in Windows: Print a PDF, Copy and Print photos now send the pages straight to the printer over the network, in its own format, with no driver and no administrator. Where Windows has a queue for it, the queue stays the default and Print offers "Print straight to the printer" too. You see each page print, and the print queue card lists the printer's own jobs.
- Batch print, a scan preset's "print a copy" and job notifications work with those printers too: each file of a batch goes straight to the printer, one after the other, and a job the printer stops ends the batch there so nothing prints twice; job notifications tell you when the printer gives up on your job or it stops moving. The command line prints to them too: give the printer's name, or its address as ipp://….
- Copy with the printer itself: an HP printer that takes copy requests can copy on its own when you press Copy, with the settings on its control panel, and needs no Windows queue. Through this PC stays the choice for your own copies, collating and two-sided settings and the preview.
- Copies through the PC can put 2 or 4 pages on each sheet, come out uncollated (all the copies of page 1, then of page 2), and wait in a preview until you press Print.
- Scan from the printer's button: on an HP printer that offers Scan to Computer, turn it on in the Scan tab and this PC appears on the printer's panel; choose it there and press Scan, and your chosen scan preset runs here while Inkvolt Print or its icon in the notification area is running. A scanner whose Windows driver reports its button does the same; a printer with neither says so.
- Inkvolt Pro (free for now): share a scanner on the network. A USB scanner, or an all-in-one that can't scan over the network, can be used from an iPhone or Android scan app, a Mac's Image Capture or another PC: turn on Share this scanner on the network in its Scan tab, or from the icon in the notification area. It's off until you turn it on, works only on networks Windows calls Private and only while Inkvolt Print runs, and the card shows the certificate's fingerprint to compare.
- Scanners whose Windows driver sends only PDF now scan like any other: their pages come into the Scan tab for the review, text recognition and presets.
- Scanners with a newer (WIA 2.0) Windows driver: the Scan tab shows how far each page is, Stop stops the page being scanned, and the glass and the feeder each offer their own resolutions.
- A scanner whose only driver is an old 32-bit TWAIN driver is now listed by its name and says why it can't be used here and which driver to install, instead of not showing at all.
- Clean up's Whiten no longer makes faded pages harder to read once their colors are restored.
- Supplies show the pages left and how many pages a full cartridge is rated for on more printers: newer HP printers, and other brands' printers that count their toner in pages. Their pages printed, and pages since each cartridge went in, show too.
- SNMP access… with an SNMPv3 user (Inkvolt Pro) works with more printers: choose the protocol the printer uses beside each passphrase, SHA-256, SHA-1 or MD5 for authentication and AES-128, AES-192, AES-256 or DES for privacy.
- A printer whose web page is on a port of its own can be added by that address (for example http://192.168.1.20:8080), and one that announces its page on the network is read there by itself.
- The printer's status shows what its control panel says, when that tells you more than the status does.
- Printers Windows set up through WSD now show the printer's own status and toner or ink levels when the printer answers SNMP, as printers on a TCP/IP port do.
- A printer added, removed or renamed in Windows shows on the printer list, goes or takes its new name within a second or so, instead of at the next check.
- Batch scanning splits at QR codes too: a sheet with a QR code or barcode that says PATCHT (as Paperless-ngx prints them) starts a new file, like a patch code sheet. The separator sheet Inkvolt Print saves for you now carries one beside its bars.
- Get the driver now finds Canon, HP and Brother drivers and PFU's (Fujitsu and Ricoh fi and SP scanners) too, each from the maker's own site and signed by the maker, as it does for Epson.
- What's new is in Spanish when Inkvolt Print is.
- Help › Open log folder in the Microsoft Store version opens the folder its log is really kept in, which Windows keeps in the app's package folder. Get the driver shows Brother's, Canon's and PFU's licence before downloading their driver, which you accept with Accept and download.

## 1.6.0
- SNMP access… now asks the printer before saving: it says which part the printer refused, or that another device answered, and keeps nothing; when the printer doesn't answer, or the refusal may not come from your printer, Save anyway keeps it as it is.
- A printer that refuses its SNMP login now says so, with which part and an SNMP access… button, instead of showing as offline, and its notification says so too.

## 1.5.0
- A USB scanner plugged in with no driver now shows on the printer list and in the Scan tab as "Plugged in, needs its driver", the moment it's plugged in.
- Get the driver: for Epson scanners and printers, Inkvolt Print finds Epson's own driver for your model and your PC on Epson's website and shows its name, version and size. Download it from Epson opens that download in your browser; run Epson's installer, and Inkvolt Print sees the scanner arrive and opens its Scan tab. (Installed from Inkvolt's own installer rather than the Store, it downloads the driver, checks that Epson signed it and installs it when you say so.)

## 1.4.0
- Scanners with only a TWAIN driver (film scanners, older flatbeds and document scanners) now show on the printer list, with their printer or on their own, and scan in the Scan tab like any other: glass or feeder, both sides, color, grey or black and white, and the same review, clean up and presets. The driver's own window doesn't open. A scanner with a Windows driver too is listed once.
- Scan in black and white: the Color choice in the Scan tab now offers it when the scanner does.
- TWAIN scanners still show when Windows' own scanner service isn't answering, and the scanners it listed before stay on the list.
- Job notifications: a job missing from one look at the queue no longer starts its stuck wait over, a failed job is told on time while the window is closed, and a job just told isn't told again after a restart.
- Clean up's note about the paper's edge counts only pages where the edge was looked for and not found, not a page you cropped yourself or one not checked yet.

## 1.3.0
- A USB printer Windows has no driver for now shows on the printer list as *Plugged in, needs its driver*, with what to do step by step: its maker's driver page (HP's for an HP), Windows Update's optional updates, or adding it in Windows. It says so when Windows protected print mode keeps makers' drivers out. Once a driver is in but Windows made no queue, *Set it up* makes one. Some older printers (host-based USB lasers) only ever work with their maker's driver.
- USB printers (and others set up in Windows) can show their ink or toner levels: a printer Windows set up with its own IPP driver, over USB or the network, is asked for its levels and problems the way a Wi-Fi printer is, and the page says where they came from. On a maker's driver, the driver is asked next ("From its driver"), when it can say. One that reports none says "Not reported by this printer".
- Inkvolt Print speaks Spanish: it follows Windows' language, or choose under Settings › Language (Same as Windows, English or Español). It takes effect the next time the app starts.
- Print a PDF works on any screen: the Print button stays in sight under the options, which scroll when the window is short. On smaller screens it could be cut off with no way to reach it.
- On a small or scaled laptop screen the window fits: its title bar with Minimize and Close was above the top of the screen.
- Windows 10: the window has a solid background and every icon shows.
- Scan review: a page you put back with Undo, the page taking a deleted one's place and a page you move now ease into place. Nothing moves while a scan or save is running, or when Windows' animation effects are off.
- Ctrl+K reaches every printer's menu: type a printer's name and a command ("front desk fix") to run it on that printer straight away, without showing it first.
- Printers that answer only SNMP can have their own community: enter it under SNMP access when you add the printer by its address, or change it later from the printer's menu (SNMP access…). It's kept in Windows Credential Manager and used only to read the printer.
- Inkvolt Pro (free for now): SNMPv3. For a printer that answers only SNMPv3, enter its user name and its two passphrases instead of a community. Every request is signed and encrypted (SHA-256, AES-128), and Inkvolt Print says whether the printer refused the user name or a passphrase.
- A printer's long problem message wraps on its status card; it was cut off at the card's edge.

## 1.2.0
- Batch print: Print › Batch takes many PDFs and pictures, or a folder. Each file has its own copies, pages, sides and paper, and you see the sheets each takes and in all before anything prints. They go in order, each result is listed, and a batch that stops says where and carries on from there without printing anything twice.
- A file that changed or vanished after the estimate isn't printed, and a page range or paper a file or printer doesn't have is said on its line, never changed quietly.
- Inkvolt Pro (free for now): save a batch as a list, keep the results as a spreadsheet file, print a folder as files land in it, and print from a script or a scheduled task with inkvoltprint print --list file --printer name.
- Clean up scans: crop to the paper, whiten the background and remove specks, take the dots out of printed pictures, and restore faded colors. Turn each on for a scan or a preset, or per page in the review, and Undo puts it back.
- Searchable PDFs now work in any language: Greek, Cyrillic, Arabic, Hebrew, Chinese, Japanese, Korean and more can be found in the hidden text. If you have several OCR languages installed, choose one under Text language.
- Fleet: a new page, from the button at the top of the printer list, shows every printer at once with its state, ink or toner levels, page count, firmware and when it was last read, the ones in trouble first.
- Fix it… now works on printers known only to Windows too (USB, shared from another PC): it finds a paused queue, Use Printer Offline and stuck jobs, and fixes them after asking. Resuming a queue and turning off Use Printer Offline now ask first on every printer, since waiting jobs start printing.
- Inkvolt Pro (free for now): Export… on the Fleet page saves the list as a spreadsheet file or JSON, inkvoltprint status --all --json gives a script or a scheduled task the same list, and Fix all resumes paused queues and turns off Use Printer Offline everywhere, asking about each one.
- Job notifications: turn on "Tell me when my own print job fails or gets stuck" in Settings, and your job's failure, or no progress for 5 minutes on a ready printer (15 if the printer says it's printing), tells you, with the document's name and Open the queue. A stuck job tells you again only if it moved in between, three times at most. Off unless you turn it on. Other people's jobs never raise one.
- Report a problem can record the printer shown: every reply Inkvolt Print reads from it, read only, with serial numbers, addresses and names taken out, saved as a .zip file for you to read and attach. Nothing is sent.

## 1.1.0
- Ink and toner history: Inkvolt Print keeps a reading a day on your PC and shows a chart of the levels over the last year, about how many days each cartridge has left, and how many pages you've printed since it went in. Low-ink alerts say how many days are left too. Export history… saves it all as one spreadsheet file (an Inkvolt Pro feature, free for now).
- Firmware watch: when a printer's firmware changes, Inkvolt Print says so on its status card ("Firmware changed from … to … on …") and, with alerts on, once in a notification.
- HP printers: Keep my cartridges working, in Printer settings › Firmware, turns automatic firmware updates off in one click, so an update that blocks non-HP cartridges can't install by itself, and checks the printer kept it.
- Press Ctrl+K to find any command by typing: show another printer, go to Scan, run a scan preset, fix printing problems, open Settings… Up and down choose, Enter runs it.
- With a large Text size or a small window, the printer list folds into a Printers button at the top, as Windows Settings does, so the printer's page keeps its room. Press it to open the list over the page.
- Changing tabs or printers, and a new status line, now ease in briefly instead of switching at once. Nothing moves when Windows' animation effects are off.
- Alerts are proper Windows notifications now: one per printer, with Open printer and Pause alerts buttons, kept in Notification Center. A newer alert for the same printer replaces the one still showing.
- Microsoft Store version: Start with Windows is offered in Settings › Notification area and alerts, straight into the notification area; Task Manager's Startup apps lists it and can turn it off.
- Help › Inkvolt Pro…: enter an Inkvolt Pro licence key, see whom it's licensed to, or remove it. One key covers Inkvolt Print and Inkvolt PDF on this PC: enter it in either app and the other finds it. Everything stays free while the apps launch; a licence ($19, one time, no account, checked on your PC and never sent anywhere) supports the project and keeps the Pro features for you when they start asking for a key.
- Undo in the scan review: a deleted page comes back, and so does a turn, a crop or a move (the Undo button, or Ctrl+Z). The status line says how after you delete a page.
- In the scan review, Ctrl+R and Ctrl+L turn the selected page and Ctrl+S saves it as a PDF. Help lists them.
- Scanners that only send PDF from the feeder now scan like the others: the pages show up for review, and turning, cropping, straightening, skipping blank pages, splitting into files, text recognition and presets all work. Saved as PDF without changes, the file is exactly the PDF the scanner sent.
- Inkvolt Print follows Windows' Text size (Settings › Accessibility): everything gets larger with it. At large sizes the tabs wrap in order and the Print a PDF and Scan buttons move under the printer's name.
- Questions ("Remove this printer?", "Discard the pages?") show the question as the heading and in the title bar, with the explanation under it; a message that only informs closes with Close.
- The Scan settings' captions stay clear of the scrollbar, as does What's New's text.
- Links and the scan review's page buttons (turn, crop, delete) are easier to hit (at least 24 px) and show a focus ring when reached with Tab.
- Add a printer's address box shows an example until you type.
- For anyone helping test printers: inkvoltprint record <address> <folder> saves everything Inkvolt Print reads from a printer, with serial numbers, addresses and names taken out, so your printer's quirks can become part of Inkvolt Print's tests. It only reads; nothing on the printer changes.

## 1.0.8
- Once Inkvolt Print has saved a few of your scans or sent a few prints over at least two days, it asks one time whether you'd like to rate it in the Microsoft Store, in the Store's own window. It never asks again, whatever you choose.

## 1.0.7
- Add a printer: searches your network for printers that don't show up by themselves, puts back printers you removed, helps with USB printers, and takes an address or printer URL.
- Unsaved scans come back after a crash in more cases (after a save, while a dialog was open), and a printer with unsaved scans stays listed.
- The scan review fits small windows.
- Opening several files with Inkvolt Print at once opens them all.
- Report a problem masks more personal details and keeps model numbers and versions readable.

## 1.0.6
- The Overview uses the whole window: its cards widen to fill it.
- Add a printer by address: type the address straight away.

## 1.0.5
- Unsaved scans are kept on disk: after a crash, a killed app or a power cut they come back in the Scan tab.
- Settings in one place: theme, where scans are saved, opening scans in Inkvolt PDF, presets, the notification area and alerts, and Reset to defaults.
- Help (F1): keyboard shortcuts, tips for finding a printer, Report a problem (copies the details a report needs, with addresses and serial numbers masked; nothing is sent by the app) and the log folder.
- The printer list says why a printer needs attention ("Ready · Yellow ink is low").
- Copy: actual size or fit to paper.
- Light or dark theme, and the window opens where you left it.
- With no printer found yet, the window no longer shows printer buttons and tabs that have nothing to act on.

## 1.0.4
- Ink and toner levels still show when a printer's own supply report fails: Inkvolt Print falls back to the standard printing protocol.
- Each status refresh asks the printer once instead of twice.
- An older printer known only over SNMP that moves to a new network address is checked by its serial number before it's shown there.

## 1.0.3
- Printers already set up in Windows show up too, USB printers included, with the status Windows and the printer's driver report, the print queue, PDF and photo printing.
- Older network printers that don't speak IPP show their status, alerts and toner or ink levels over SNMP.
- Scanners without AirScan (USB, or with only a Windows driver) scan through Windows, into the same review, searchable PDF, presets and copy features.
- A queue Windows can't reach (a shared printer's PC turned off, a stopped print service) says so instead of looking removed.
