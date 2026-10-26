# Inkvolt for macOS: plan

Decided 2026-10-26 with the owner:

| | |
|---|---|
| Apps | Inkvolt Print first; Inkvolt PDF after it ships |
| Stack | Native Swift: SwiftUI with AppKit where needed; Apple frameworks only |
| Distribution | Print: Mac App Store (sandboxed). PDF: notarized DMG with Sparkle 2, MuPDF, AGPL |
| Minimum | macOS 15 Sequoia |
| Price | Free; no account, no telemetry, no cloud |
| Signing | The Apple team that signs the Inkvolt mobile builds |
| Repo | This monorepo, `mac/`; shares fixtures and glossaries with the Windows apps |

Platform facts and their sources: [`research/print-v1-platform.md`](research/print-v1-platform.md).

## Inkvolt Print v1 scope

In:
- printer status, supplies and alerts (LEDM, CDM, IPP, SNMP; same fallback order and identity-before-data rule);
- Add a printer: Bonjour, the subnet search (TCP 631/9100/515, SNMP broadcast), a typed address;
- scanning: eSCL presets with review, crop and straighten, crash recovery; USB scanners through ImageCaptureCore;
- the offline fixer, reduced to diagnosis, cancelling the user's own stuck jobs, and a guided hand-off to Printers &
  Scanners (the sandbox can't resume, re-enable, add or delete a CUPS queue);
- a menu bar item (the tray's equivalent) with alerts; launch at login only if the user turns it on;
- demo mode (the made-up environment), so App Review can use the app without a printer.

Later (Windows features not in v1): copy, print photos, print a PDF, HP maintenance (cleaning, alignment), firmware
update, LEDM settings, batch scans with separator sheets and patch codes, glass photos, mail and sync-folder routes,
Open in Inkvolt PDF.

## Layout

```
mac/
  CLAUDE.md, README.md
  docs/PLAN.md                   this file
  docs/research/                 platform research, one file per question set
  Probe/                         InkvoltProbe: throwaway sandboxed app that settles the open platform questions (P0)
  InkvoltPrintKit/               Swift package (from P1)
    Sources/PrintCore/           protocols and rules; Foundation only, so it also builds off the Mac
    Sources/PrintMac/            adapters: URLSession, BSD-socket SNMP, NWBrowser, subnet scanner, libcups,
                                 ImageCaptureCore, Keychain, Core Image, PDFKit, Vision
    Tests/PrintCoreTests/        Swift Testing; reads print/tests/InkvoltPrint.Tests/Fixtures in place
  InkvoltPrint/                  Xcode app project (made on the Mac; folder-synced groups), SwiftUI, uses the package
```

## Module map (.NET to Swift)

| `shared/InkvoltPrint.Core` | Swift | Notes |
|---|---|---|
| `Snmp/` (Ber, Oid, SnmpMessage, PrinterMib, SnmpPrinterStatus, SnmpPrinterClient) | `PrintCore/Snmp` | transport behind a protocol; `SnmpAgent` becomes the test fake |
| `Ipp/` | `PrintCore/Ipp` | the same encoder reads the local cupsd |
| `Ledm/`, `Cdm/` (parsers, status text) | `PrintCore/Ledm`, `PrintCore/Cdm` | `XMLParser` with external entities off and the same depth caps as `Net/DeviceXml` |
| `Net/` (DeviceHttp policy, FixtureHandler, HostRouter) | `PrintCore/Net` + `PrintMac/Http` | size caps, timeouts, certificate pins; `FixtureHandler` becomes a `URLProtocol` fake |
| `Model/`, `Probe/` | `PrintCore/Model`, `PrintCore/Probe` | PrinterReading, printer status, PrinterSession, connection recipe |
| `Alerts/`, `Suite/PrinterHealth`, tray text | `PrintCore/Alerts` | feeds the menu bar |
| `Discovery/` (NetworkSearch, DnssdJoin, PrinterAddress) | `PrintCore/Discovery` + `PrintMac/Discovery` | address planning stays pure; sockets and NWBrowser in PrintMac |
| `Queues/` (PrinterList, QueueKinds, SnmpQueueStatus) | `PrintCore/Queues` + `PrintMac/Cups` | Windows queues become CUPS destinations |
| `Escl/`, `Presets/` (ScanPreset, FileNameTemplate), `Imaging/ScanRecovery` | `PrintCore/Scan` | |
| `Imaging/PageImage` (rotate, deskew, crop) | `PrintMac/Imaging` | Core Image; the edit model stays in PrintCore |
| `Offline/` (diagnosis) | `PrintCore/Offline` | repairs become hand-off steps |
| `Wia/` | `PrintMac/Icc` | ImageCaptureCore; `FakeWiaSystem`'s role goes to a fake scanner protocol |
| `Pdf/PdfWriter` | `PrintMac/Pdf` | PDFKit / Core Graphics; searchable PDF with Vision |

Not ported: `Suite/ShellRegistration`, `Offline/RepairScripts`, `Queues/Spooler*`, `Wia/WorkThread`, and the v1
"Later" list above.

## Steps

Each port step ports the module's .NET tests first, under the same names (in lower camel case), then the code until
they pass. PrintCore builds and tests on the Windows PC too: `pwsh -File mac/tools/swift-dev.ps1 test --package-path
mac/InkvoltPrintKit --build-system native`.

| Step | What | .NET tests to port | Status |
|---|---|---|---|
| P0 | Probe app on `ignia-mac`: answer research open items 1 to 10; record results in the research file | | Builds in CI; run pending |
| P1 | Package skeleton, CI job (`swift test` on a macOS runner), Model, SNMP | SnmpTests | Done: 42 tests. The connection and Windows queue tests wait for P4 and P7 |
| P2 | IPP | IppAndPdfTests (IPP part) | Done: 22 tests (codec, text fixtures, status, supplies, Identify-Printer, from OtherBrandsTests, RobustnessTests and MaintenanceTests too). The HTTP client waits for P4 |
| P3 | LEDM, CDM, other brands' status text | LedmTests, CdmTests, OtherBrandsTests | Done: 22 tests (LEDM documents and manifest, CDM identity, supplies and status, brands, the hardened XML and JSON readers). The connection, eSCL and web-page tests wait for P4 and P8 |
| P4 | Device HTTP, printer status, printer session, certificate pins | PrinterReadingTests, PrinterSessionTests, RobustnessTests, CertificatePinTests | Done: 78 tests (device HTTP, pins per port, the fixture transport, LEDM, CDM, IPP and eSCL clients, the connection probe, printer reader and printer session, printer ids; with the connection tests SnmpTests, CdmTests and OtherBrandsTests left for here, and eSCL from P8). The TLS handshake tests wait for PrintMac |
| P5 | Alerts, status lines | AlertTests, StatusLineTests | Done: 35 tests (conditions, the tracker's holds, quiet hours, pause, memory across restarts, polling, menu bar text, list lines) |
| P6 | Discovery: typed addresses, network search planning, DNS-SD join | NetworkSearchTests | Done: 21 tests (typed addresses, the search's addresses, SNMP question, reporting once, stopping; DNS-SD join and endpoints from OtherBrandsTests). The socket scanner is PrintMac's |
| P7 | Printer list with CUPS destinations | PrinterListTests, QueuePrinterTests (CUPS parts) | |
| P8 | Presets, file names, scan recovery, page edits (eSCL came with P4a) | ScanPresetTests, ScanRecoveryTests, ImagingTests | |
| P9 | Offline diagnosis | OfflineFixerTests (diagnosis parts) | |
| P10 | App: main window, Add a printer, scan review, offline fixer, menu bar, settings, demo mode | DemoTests | |
| P11 | App Store: record, privacy label "Data Not Collected", review notes (demo mode, why `network.server`, the subnet search), screenshots | | |

## Mac differences

- SNMP errors are Swift errors: `SnmpFormatError`, `SnmpTimeoutError`, `SnmpErrorStatus` (the .NET exceptions).
- IPP attribute values are an enum (`IppAttributeValue`: text, integer, boolean, bytes), not `object`.
- Device XML is read with `XMLParser` into a small tree (`XmlElement`, by local name); a document with a DTD is refused
  before parsing. CDM's JSON goes through a small reader of its own (`Json`: numbers keep their text, nesting capped at 64)
  rather than JSONSerialization, whose booleans and numbers differ between Darwin and other platforms.
- HTTP goes through PrintCore's own `HttpTransport` (request and response values; `DeviceNetworkError` for no answer),
  so PrintCore never opens a socket: PrintMac's URLSession transport and the fixture transport sit behind it.
  `CertificateCheck` holds the pin rule the TLS transport asks on each handshake; the loopback TLS tests
  (CertificatePinTests' handshakes) move to PrintMac. To check there: URLSession treats `Host` and `Authorization` as
  reserved headers, which the Epson eSCL quirk and the EWS password need.
- The IPP probe asks the DNS-SD hint and the plain endpoint at the same time, so which is asked first isn't fixed.
- A printer added by address keeps the Windows app's id (MD5 of the host as a .NET Guid; PrintCore has its own MD5 and
  SHA-256, since CryptoKit is Apple's).
- Quiet hours are minutes after midnight on a given time zone (the tracker takes one; tests pass UTC-4 as the .NET tests'
  offset). Polling backs off on battery and on a constrained network (macOS's Low Data Mode) rather than Windows' metered one.
- Network search addresses are dotted IPv4 strings; the scanner protocol is async (`NetworkScanner`), and the sweep runs
  64 addresses at a time in a task group, the SNMP question beside it and awaited when the search stops.
- `PrinterSession` is an actor; its clock is a `now` closure, and a dropped connection simply goes (no Dispose).
- `SnmpPrinterClient` is an actor; a caller's cancellation doesn't stop waiting for a shared read (each read times out on
  its own, 1 s per request).

## Open decisions

- Bundle IDs: proposed `com.bermudezsystems.InkvoltPrint` and `com.bermudezsystems.InkvoltPdf` (the probe uses
  `com.bermudezsystems.InkvoltProbe`).
- Where the repo is cloned on `ignia-mac` (proposed `~/Repos/inkvolt`, next to `inkvolt-mobile`).
- Swift on this Windows PC: the Windows toolchain could build and test `PrintCore` here (Foundation only); not installed.
