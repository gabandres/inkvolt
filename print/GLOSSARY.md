# Glossary

Domain terms Inkvolt Print's modules are named after. Plain English; the code's doc comments say how.

- **Printer reading**: one read of a printer's state: its status, supply levels and usage counters
  (`PrinterReading`, from `PrinterConnection.ReadAsync`).
- **Printer status**: the module that takes a reading over whichever interfaces the printer answered on, in one fallback
  order (LEDM, CDM, IPP, SNMP) with one error rule: no answer means offline, an error reply means "ask the next
  interface" (`PrinterReader` in `shared/InkvoltPrint.Core/Probe`).
- **Interface** (of a printer): a protocol it answers on: HP's LEDM and CDM, IPP, SNMP's Printer MIB, eSCL for scanning.
