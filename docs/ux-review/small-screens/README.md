# Small screens and Windows 10 (Inkvolt Print, 2026-11-03)

The owner, on an older PC (almost certainly Windows 10) with Print 1.2.0 from the Store: no window frame, no caption
buttons (couldn't minimize), the Print button cut off or missing, "I can't print at all choosing a PDF".

**Causes found**

1. **Print was cut off at almost any height.** The One PDF options card (Document, Pages, Copies, Size, summary, Print) had
   no scroll viewer (the Copy tab's has one): with a PDF chosen its bottom, the Print button, was clipped with no way to
   reach it. The default 1180 × 800 window already cut it in half (`before/printpdf-default-w11-Light`); any shorter one
   hid it (`before/printpdf-1024x576-w11-Dark`).
   Now the options scroll and Print, Cancel and the message are pinned under them (`after/`), at every size down to the
   window's minimum with Text size 125 %. The empty page's "Drop a PDF here / Choose a PDF…" scrolls too.
2. **The window was larger than a small screen.** 1180 × 800 opened centred on a 1366 × 768 laptop (work area 1366 × 728)
   puts the title bar 36 DIPs above the top; at 125 % (1092 × 582) 109 DIPs above and 44 off each side: no frame, no
   caption buttons, the header's right edge cut. Now the window (and its minimum size) is no larger than the working area
   before it shows, and every window is kept on its monitor when it loads (`ScreenFit` in Core, tested; logged).
3. **Windows 10 itself**: WPF's Fluent theme already gives Windows 10 an opaque window and no backdrop (checked in WPF's
   source: `WindowBackdropManager`, `Styles/Window.xaml`). Inkvolt Print now asks for Mica only from build 22621, sets the
   theme's opaque background below it (Windows 11 21H2 showed a transparent one), and takes its icons, and the Fluent
   theme's, from Segoe MDL2 Assets alone before Windows 11. Every glyph both apps use is in Segoe MDL2 Assets
   (`WindowsLookTests.EveryIconGlyphIsInSegoeMdl2Assets` reads the font's cmap), so none needed mapping.

**The shots** (`--demo --snapshot`, 1.5× pixels; `frame-*` are the real window with its frame, on a work area faked to
1092 × 582): `w11` this PC, `w10` with `INKVOLT_FAKE_WIN10=1` (WPF and the app take their Windows 10 path; Windows 11's DWM
still draws the frame), `ts125` with `INKVOLT_TEXTSCALE=1.25`. At 860 × 560 with Text size 125 % the options get only a
sliver above Print (they scroll); the printer's header takes the rest.

**Checks**: `WindowsLookTests.PrintIsInSightAtSmallSizes` runs the app (demo printer, a made-up PDF opened in Print) at
860 × 560 and 1024 × 576, as Windows 11 and as Windows 10 with Text size 125 %, checks the Print button is whole and in
sight and presses it through its automation peer (`--press-print`); it fails on the old layout.
