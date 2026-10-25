# Glossary

Domain terms Inkvolt Print's modules are named after. Plain English; the code's doc comments say how.

- **Printer reading**: one read of a printer's state: its status, supply levels and usage counters
  (`PrinterReading`, from `PrinterConnection.ReadAsync`).
- **Printer status**: the module that takes a reading over whichever interfaces the printer answered on, in one fallback
  order (LEDM, CDM, IPP, SNMP) with one error rule: no answer means offline, an error reply means "ask the next
  interface" (`PrinterReader` in `shared/InkvoltPrint.Core/Probe`).
- **Environment** (this PC's): everything outside the app that it reaches: the network, Windows' print queues and
  scanners, the offline fixer's checks and repairs, saved passwords, the browser. Chosen once at start-up: the real PC or
  demo mode's made-up one (`PcEnvironment`, `Demo.Pc`).
- **Made-up PC**: demo mode's environment. Nothing it does reaches the network or this PC; nothing prints for real.
- **Interface** (of a printer): a protocol it answers on: HP's LEDM and CDM, IPP, SNMP's Printer MIB, eSCL for scanning.
