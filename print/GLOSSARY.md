# Glossary

Domain terms Inkvolt Print's modules are named after. Plain English; the code's doc comments say how.

- **Printer reading**: one read of a printer's state: its status, supply levels and usage counters
  (`PrinterReading`, from `PrinterConnection.ReadAsync`).
- **Printer status**: the module that takes a reading over whichever interfaces the printer answered on, in one fallback
  order (LEDM, CDM, IPP, SNMP) with one error rule: no answer means offline, an error reply means "ask the next
  interface" (`PrinterReader` in `shared/InkvoltPrint.Core/Probe`).
- **Printer session**: one remembered network printer's connection life cycle: connect, ask who answers before reading,
  upgrade a printer read over SNMP when it answers more, check an address it is announced at (`PrinterSession`).
- **Printer monitor** (Mac): keeps one network printer's state current through its printer session: reads on the
  printer's events or every 30 s, retries every 20 s, follows an announced address, and tells the app what the printer
  pane shows (`PrinterMonitor`; the Windows app does this in `PrinterViewModel`).
- **Connection recipe**: what every connection to a printer carries: the network (or demo transport), SNMP, its
  certificate pins (`PrinterRecipe`).
- **Identity before data**: a printer's status is read only after the device at its address has said it is that printer
  (its UUID, or over SNMP its serial number); another device that took the address is never read under its name.
- **Printer list**: the printers in the sidebar: network printers, queue printers (known only by a Windows queue, or on the
  Mac a CUPS destination, no network printer stands for) and scanners on their own (a Windows scanner no printer claims), and which one is selected
  (`PrinterList` in `shared/InkvoltPrint.Core/Queues`).
- **CUPS destination** (Mac): a print queue set up in macOS, as libcups lists it with its options (`CupsDestination`). A
  temporary destination (a printer Bonjour shows that nobody set up) isn't a queue.
- **Set up in macOS** (Mac): creating the CUPS queue for a network printer macOS has none for, so every app prints to it:
  cupsd makes a temporary destination and reads the printer into a driverless (IPP Everywhere) queue, then keeps it
  (`QueueSetup`; Windows: Set up in Windows). Needs an administrator of the Mac.
- **Batch** (scan): one feeder run saved as several files, split at separator sheets or by hand (`BatchSplit`).
- **Separator sheet**: a page that starts the next file of a batch: a sheet printed with a patch code (Patch 2, 3 or T),
  a blank page, one marked by hand, or the back of a patch sheet in a two-sided scan (`Separators`, `SeparatorSheet`).
  Left out of the files unless the batch keeps them.
- **Glass photos**: several prints laid on the scanner glass at once, each found and saved as a picture of its own, cut
  out straight (`PhotoFinder`, `PhotoBox`). Their boxes can be moved, resized, turned or drawn by hand before saving
  (Windows `PhotoBoxesView`; Mac `PhotoBoxEditor`).
- **Hidden list** (forgotten): entries the user removed; they stay hidden until Windows no longer has them, or until a
  network printer is added again by address.
- **Environment** (this PC's): everything outside the app that it reaches: the network, Windows' print queues and
  scanners, the offline fixer's checks and repairs, saved passwords, the browser. Chosen once at start-up: the real PC or
  demo mode's made-up one (`PcEnvironment`, `Demo.Pc`).
- **Made-up PC**: demo mode's environment. Nothing it does reaches the network or this PC; nothing prints for real.
- **Interface** (of a printer): a protocol it answers on: HP's LEDM and CDM, IPP, SNMP's Printer MIB, eSCL for scanning.
- **Supply history**: the levels and page counts kept on this PC, one row a day per supply per printer
  (`Core/History/SupplyHistoryStore`); what it says (cartridges, days left, the chart) is worked out from it, never stored.
- **Cartridge** (in the history): the rows between two changes of cartridge, a change being a level that jumps up by 20
  points or more (`SupplyAnalysis`). "Seen going in" when the change is in the history; the first one usually isn't.
- **Firmware watch**: each printer's firmware version as last seen, with the day it was first seen and the change before
  it (`Core/History/FirmwareWatch`, kept in `state.json`); a change is shown until dismissed or 30 days old and alerted once.
- **Pro check** (`Pro.Allows(feature)` in `shared/InkvoltPrint.Core/Pro.cs`, on the suite's `ProCheck`): the one place a
  Pro feature asks whether it may run: yes with a **licence** (an Inkvolt Pro key, `ProKeys`, one for both Inkvolt apps,
  kept in the file both read, `ProKeyFile`, and verified on the PC), and yes for everyone while `ProCheck.Enforced` is
  off (the launch period).
- **Local Network access** (Mac): macOS's permission to reach devices on this network. No API reads it; the app tells it
  from what the network does (`LocalNetworkSignal`): denied (or not answered yet) shows as such, never as "no printers".
