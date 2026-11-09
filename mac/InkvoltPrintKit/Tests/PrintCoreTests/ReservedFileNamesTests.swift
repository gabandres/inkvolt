import Testing
@testable import PrintCore

/// Windows' `DeviceNamesTests` (shared/InkvoltPrint.Core/DeviceNames.cs, the one rule both apps use), same cases: the
/// Mac's `ReservedFileNames`, for Inkvolt Print's scans, Inkvolt PDF's Batch and its one-click conversions.
struct ReservedFileNamesTests {
    static let devices: [String] = ["CON", "PRN", "AUX", "NUL", "CONIN$", "CONOUT$"]
        + (0...9).flatMap { ["COM\($0)", "LPT\($0)"] }
        + ["¹", "²", "³"].flatMap { ["COM\($0)", "LPT\($0)"] }

    @Test(arguments: devices)
    func EveryDeviceNameIsReservedInAnyCaseAndWithAnyExtension(_ name: String) {
        #expect(ReservedFileNames.isDevice(name))
        #expect(ReservedFileNames.isDevice(name.lowercased()))
        #expect(ReservedFileNames.isDevice(name + ".txt"))
        #expect(ReservedFileNames.isDevice(name + ".backup.pdf"))
        #expect(ReservedFileNames.isDevice(name + " "))
        #expect(ReservedFileNames.isDevice(name + "."))
        #expect(ReservedFileNames.isDevice(name + " .pdf"))
    }

    @Test(arguments: ["nul.txt", "COM1.backup.pdf", "Con", "cOnOuT$.log", "CON ", "nul.", "nul. . ", "PRN  .txt", "lpt³.txt",
                      "COM1:", "aux:stream"])
    func WhatWindowsTrimsStillNamesTheDevice(_ name: String) {
        #expect(ReservedFileNames.isDevice(name))
    }

    @Test(arguments: ["CONSOLE", "COM10", "LPT10", "NULL.pdf", "aux-notes.txt", "CON1", "COM", "LPT", "COM⁴", "COM₁", "COMA",
                      " CON", "_CON", "CON_", "nul_.backup", "CONIN", "CONOUT", "CONIN$$", ".nul", "report.con", "", "   ", "..."])
    func NearMissesStayAllowed(_ name: String) {
        #expect(!ReservedFileNames.isDevice(name))
    }

    @Test func The_list_is_Windows_own() {
        // Windows' DeviceNames: CON PRN AUX NUL, COM0–9 and LPT0–9, the six superscript ports, the two console handles.
        #expect(ReservedFileNames.devices.count == 32)
        #expect(ReservedFileNames.devices.allSatisfy { $0 == $0.lowercased() })
    }
}
