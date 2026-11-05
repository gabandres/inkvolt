# What's new in Inkvolt Print for Mac

The App Store's "What's New in This Version" for each update is made from these notes (`assets/store/listing.json`'s
`whatsNew`, which `asc-listing.mjs apply` sends). Each release gets a `## x.y` heading before it's submitted; `## Next`
collects what's done since the last release. Short lines, in the user's words.

## Next
- Ink and toner history: Inkvolt Print keeps a reading a day on your Mac and shows a chart of the levels over the last year, about how many days each cartridge has left, and how many pages you've printed since it went in. Low-ink alerts say how many days are left too. Export history… saves it all as one spreadsheet file (an Inkvolt Pro feature, free for now).
- Firmware watch: when a printer's firmware changes, its status card says so. HP printers: Keep My Cartridges Working, in the Settings tab, turns automatic firmware updates off, so an update that blocks non-HP cartridges can't install by itself.
- Scanners that send only PDF work, and a scan saved untouched is kept exactly as the scanner sent it.
- Help › Inkvolt Pro…: enter an Inkvolt Pro key; Inkvolt PDF on this Mac finds it too.

1.0 and 1.1 (build 5, submitted 2026-11-04) had their notes in `listing.json` only.
