# What's new in Inkvolt Print

Shown in the app once after an update (Help › What's new any time) and used for the Store's "What's new in this version".
Each release gets a `## x.y.z` heading before it's packed (`packaging/pack-msix.ps1` warns when the version has none);
`## Next` collects what's done since the last release and is never shown. Short lines, in the user's words.

## Next
- Ink and toner history: Inkvolt Print keeps a reading a day on your PC and shows a chart of the levels over the last year, about how many days each cartridge has left, and how many pages you've printed since it went in. Low-ink alerts say how many days are left too. Export history… saves it all as one spreadsheet file (an Inkvolt Pro feature, free for now).
- Firmware watch: when a printer's firmware changes, Inkvolt Print says so on its status card ("Firmware changed from … to … on …") and, with alerts on, once in a notification.
- HP printers: Keep my cartridges working, in Printer settings › Firmware, turns automatic firmware updates off in one click, so an update that blocks non-HP cartridges can't install by itself, and checks the printer kept it.
- Alerts are proper Windows notifications now: one per printer, with Open printer and Pause alerts buttons, kept in Notification Center. A newer alert for the same printer replaces the one still showing.
- Microsoft Store version: Start with Windows is offered in Settings › Notification area and alerts, straight into the notification area; Task Manager's Startup apps lists it and can turn it off.
- Help › Inkvolt Pro…: enter an Inkvolt Pro licence key, see whom it's licensed to, or remove it. One key covers Inkvolt Print and Inkvolt PDF on this PC: enter it in either app and the other finds it. Everything stays free while the apps launch; a licence ($19, one time, no account, checked on your PC and never sent anywhere) supports the project and keeps the Pro features for you when they start asking for a key.
- Undo in the scan review: a deleted page comes back, and so does a turn, a crop or a move (the Undo button, or Ctrl+Z). The status line says how after you delete a page.
- In the scan review, Ctrl+R and Ctrl+L turn the selected page and Ctrl+S saves it as a PDF. Help lists them.
- Inkvolt Print follows Windows' Text size (Settings › Accessibility): everything gets larger with it. At large sizes the tabs wrap in order and the Print a PDF and Scan buttons move under the printer's name.
- Questions ("Remove this printer?", "Discard the pages?") show the question as the heading and in the title bar, with the explanation under it; a message that only informs closes with Close.
- The Scan settings' captions stay clear of the scrollbar, as does What's New's text.
- Links and the scan review's page buttons (turn, crop, delete) are easier to hit (at least 24 px) and show a focus ring when reached with Tab.
- Add a printer's address box shows an example until you type.

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
