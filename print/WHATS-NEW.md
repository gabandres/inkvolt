# What's new in Inkvolt Print

Shown in the app once after an update (Help › What's new any time) and used for the Store's "What's new in this version".
Each release gets a `## x.y.z` heading before it's packed (`packaging/pack-msix.ps1` warns when the version has none);
`## Next` collects what's done since the last release and is never shown. Short lines, in the user's words.

## Next
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
