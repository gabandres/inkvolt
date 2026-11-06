# Glossary

Domain terms Inkvolt Print's modules are named after. Plain English; the code's doc comments say how.

- **Interface language**: the language the app's own words are in, picked once at start-up (`AppLanguage`, the choice in `UiLanguage`) and read from `Strings` and `CoreStrings`. What a printer sends stays as it sends it. A supply's **key** (`Consumable.Key`) is its English name whatever the language: what its history and alerts go by.
- **Printer reading**: one read of a printer's state: its status, supply levels and usage counters
  (`PrinterReading`, from `PrinterConnection.ReadAsync`).
- **Printer status**: the module that takes a reading over whichever interfaces the printer answered on, in one fallback
  order (LEDM, CDM, IPP, SNMP) with one error rule: no answer means offline, an error reply means "ask the next
  interface" (`PrinterReader` in `shared/InkvoltPrint.Core/Probe`).
- **Printer session**: one remembered network printer's connection life cycle: connect, ask who answers before reading,
  upgrade a printer read over SNMP when it answers more, check an address it is announced at (`PrinterSession`).
- **Printer monitor**: keeps one network printer's state current through its printer session: reads on the
  printer's events or every 30 s, retries every 20 s, follows an announced address, watches its firmware, and tells the
  app what the printer pane shows (the **printer view**) and what to bind or let go of (`PrinterMonitor`, `PrinterView`,
  `MonitorEvent` in `shared/InkvoltPrint.Core/Probe`; the Windows app runs it on its dispatcher and only shows it).
- **Connection recipe**: what every connection to a printer carries: the network (or demo transport), SNMP, its
  certificate pins (`PrinterRecipe`).
- **Identity before data**: a printer's status is read only after the device at its address has said it is that printer
  (its UUID, or over SNMP its serial number); another device that took the address is never read under its name.
- **Printer list**: the printers in the sidebar: network printers, queue printers (known only by a Windows queue, or on the
  Mac a CUPS destination, no network printer stands for) and scanners on their own (a Windows scanner no printer claims), and which one is selected
  (`PrinterList` in `shared/InkvoltPrint.Core/Queues`).
- **Needs its driver**: a USB printer plugged in that nothing can print to: Windows has only its placeholder driver (or none), or
  has a driver and made no queue (*not set up*). Listed on the printer list with what to do; never a queue printer
  (`NeedsDriver` in `shared/InkvoltPrint.Core/Queues`).
- **CUPS destination** (Mac): a print queue set up in macOS, as libcups lists it with its options (`CupsDestination`). A
  temporary destination (a printer Bonjour shows that nobody set up) isn't a queue.
- **Set up in macOS** (Mac): creating the CUPS queue for a network printer macOS has none for, so every app prints to it:
  cupsd makes a temporary destination and reads the printer into a driverless (IPP Everywhere) queue, then keeps it
  (`QueueSetup`; Windows: Set up in Windows). Needs an administrator of the Mac.
- **Hand-off** (Mac): the printers Inkvolt Print remembers, written to the app group both Mac apps claim
  (`Inkvolt/printers.json`, `SuitePrinters`) for Inkvolt PDF's printer status when printing; Windows' Inkvolt PDF reads
  `state.json` instead. Inkvolt Print writes it, Inkvolt PDF only reads it. A printer's **health** (`PrinterHealth`) is its
  state reduced to what matters before printing (ready, sleeping, busy, needs attention, error, offline, toner, paper).
- **Batch** (scan): one feeder run saved as several files, split at separator sheets or by hand (`BatchSplit`).
- **Batch print**: many files sent in order, a job for each (`Core/Printing/BatchPrint`). Not the scan batch above. Its **estimate** is the sheets a file comes to, read from the file itself before anything prints (`BatchMeasurer`, `BatchPrintLine`); a file's **fingerprint** (its length and SHA-256) is what shows it's still what the estimate saw. **Sent** means the queue has it, not that paper came out. A **list** is a saved batch (`BatchPrintList`). A **batch print folder** is one printed as it fills (`BatchPrintFolder`); a file in its `working` folder may have printed, so it's never sent again by itself. On the Mac, its **places** are the files, folders and lists the Batch Print window was given, kept by their paths with a bookmark each so the sandboxed `print` command, and a list opened in a later launch, can reach them (`BatchPlaces`, `BatchPlaceList`, `PrintState.batchPlaces`).
- **Separator sheet**: a page that starts the next file of a batch: a sheet printed with a patch code (Patch 2, 3 or T),
  a blank page, one marked by hand, or the back of a patch sheet in a two-sided scan (`Separators`, `SeparatorSheet`).
  Left out of the files unless the batch keeps them.
- **Glass photos**: several prints laid on the scanner glass at once, each found and saved as a picture of its own, cut
  out straight (`PhotoFinder`, `PhotoBox`). Their boxes can be moved, resized, turned or drawn by hand before saving
  (Windows `PhotoBoxesView`; Mac `PhotoBoxEditor`).
- **Clean up** (of a scanned page): the filters a page can have, in its edits and undone with them: crop to the paper,
  whiten, descreen, restore colors (`PageFilters`, `PageCleanup`). **The paper's edge**: where a sheet stops differing from
  the lid (`PaperEdge`); no sure edge, no crop. The same code on the Mac (PrintCore's `PageCleanup`, RGB where Windows has BGR).
- **Text layer** (of a searchable scan PDF): the recognized words as invisible text over the page, in one CID font whose
  /ToUnicode map gives each code its letters, so any script is found by search (`PdfWriter`, `OcrText`, `OcrFont`; PrintCore's
  on the Mac). Not Inkvolt PDF's text layer, which can be read back and corrected (pdf/GLOSSARY.md).
- **Hidden list** (forgotten): entries the user removed; they stay hidden until Windows no longer has them, or until a
  network printer is added again by address.
- **Environment** (this PC's): everything outside the app that it reaches: the network, Windows' print queues and
  scanners, the offline fixer's checks and repairs, saved passwords, the browser. Chosen once at start-up: the real PC or
  demo mode's made-up one (`PcEnvironment`, `Demo.Pc`).
- **Made-up PC**: demo mode's environment. Nothing it does reaches the network or this PC; nothing prints for real.
- **PDF-only source** (of a scanner): a glass or feeder whose eSCL capabilities offer PDF and no JPEG. Scanned as PDF, its pages
  handed over as JPEG like any other scanner's (`ScannerPdf`); a file saved from them untouched is **as sent**: the scanner's own PDF.
- **Recording** (of a printer): every reply the app reads from one printer, scrubbed, in the fixtures' layout, so the test
  transports (`FixtureHandler`, `SnmpAgent`) serve it as that printer (`Core/Recording/PrinterRecorder`). **Scrubbing** gives
  each identifier a stand-in of the same shape, the same one everywhere (`FixtureScrubber`); Report a problem's masks
  (`Diagnostics.Scrub`) only blank them out. Report a problem's recording (`ReportRecording`) is one in a new folder named
  by the clock, with a .zip of it to attach (on the Mac, in the container's `Recordings`, its files stored: `ZipArchive`).
- **SNMP login** (of a printer): how it's read over SNMP: a community, or (Pro) an SNMPv3 user with two passphrases (`SnmpLogin`). A secret: kept in Credential Manager by printer id (`ISnmpLogins`), never in `state.json`; public when none is kept.
- **Interface** (of a printer): a protocol it answers on: HP's LEDM and CDM, IPP, SNMP's Printer MIB, eSCL for scanning.
- **Supply history**: the levels and page counts kept on this PC, one row a day per supply per printer
  (`Core/History/SupplyHistoryStore`); what it says (cartridges, days left, the chart) is worked out from it, never stored.
  On the Mac a printer's readings go into it through its **supply history feed** (`SupplyHistoryFeed`), which gives the card's view.
- **Cartridge** (in the history): the rows between two changes of cartridge, a change being a level that jumps up by 20
  points or more (`SupplyAnalysis`). "Seen going in" when the change is in the history; the first one usually isn't.
- **Firmware watch**: each printer's firmware version as last seen, with the day it was first seen and the change before
  it (`Core/History/FirmwareWatch`, kept in `state.json`); a change is shown until dismissed or 30 days old and alerted once.
  The printer monitor watches it through the state file's **firmware memory** (`FirmwareMemory`).
- **Pro check** (`Pro.Allows(feature)` in `shared/InkvoltPrint.Core/Pro.cs`, on the suite's `ProCheck`): the one place a
  Pro feature asks whether it may run: yes with a **licence** (an Inkvolt Pro key, `ProKeys`, one for both Inkvolt apps,
  kept in the file both read, `ProKeyFile`, and verified on the PC), and yes for everyone while `ProCheck.Enforced` is
  off (the launch period). On the Mac that file's root is the **app group container** both Mac apps claim
  (`AE6TTXW92K.com.bermudezsystems.inkvolt`, PrintMac's `ProKeyRoot`), and CryptoKit verifies the key
  (`CryptoKitProVerifier`).
- **Job alert**: a notification about one of your own print jobs (`AlertTracker.ObserveJobs`). **Failed**: the job itself reports an error, a block or a need for someone at the printer. **Stuck**: your first job in a queue that hasn't moved, the queue running, for 5 minutes with the printer saying it's ready or 15 with it saying it's printing. **Moved** (`JobProgress`): pages, size or stage past the furthest seen, not a state going back and forth. **Your own** (`JobOwner`): the signed-in Windows user's, and from this PC when the job says. **The same job** (`JobRules.Key`): same id and same submit time; the spooler uses ids again. On the Mac the job's CUPS `job-state` stands for the spooler's bits: failed is `stopped` or `aborted`, and with no page counts from CUPS a job moves only by its size, its state or a job leaving.
- **Fleet**: every entry of the printer list at once, most trouble first (`Core/Fleet`). **Trouble** is one ranking: error, warning, can't be
  reached, not known yet, fine (`FleetTrouble`). **Last known**: what the supply history and the firmware watch kept of a printer that isn't
  answering now.
- **Safe repair**: what Fix all may do, each confirmed: resume a queue, turn off Use Printer Offline (`Repair.IsSafe`). It loses nothing, moves no
  job elsewhere and interrupts no other printer; the rest stays on each printer's own fixer.
- **Local Network access** (Mac): macOS's permission to reach devices on this network. No API reads it; the app tells it
  from what the network does (`LocalNetworkSignal`): denied (or not answered yet) shows as such, never as "no printers".
