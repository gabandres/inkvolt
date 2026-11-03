# What's new in Inkvolt Print

Shown in the app once after an update (Help › What's new any time) and used for the Store's "What's new in this version".
Each release gets a `## x.y.z` heading before it's packed (`packaging/pack-msix.ps1` warns when the version has none);
`## Next` collects what's done since the last release and is never shown. Short lines, in the user's words.

## Next
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
