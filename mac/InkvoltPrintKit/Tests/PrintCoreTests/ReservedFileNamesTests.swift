import Testing
@testable import PrintCore

/// Windows' device names, one rule for Inkvolt Print's scans, Inkvolt PDF's Batch and its one-click conversions.
struct ReservedFileNamesTests {
    @Test(arguments: ["CON", "con.txt", "Nul.tar.gz", "AUX ", "prn .pdf", "COM1", "lpt9.docx", "COM¹", "com².pdf", "LPT³",
                      "CONIN$", "conout$.log"])
    func A_device_name_is_reserved_whatever_its_extension_or_case(_ name: String) {
        #expect(ReservedFileNames.isDevice(name))
    }

    @Test(arguments: ["COM10", "COM0", "LPT0", "console.txt", "connect", "nul_", "_CON", "CONIN", "COM⁴", "", ".con"])
    func Other_names_are_files(_ name: String) {
        #expect(!ReservedFileNames.isDevice(name))
    }

    @Test func The_list_is_Windows_own() {
        // Windows' 22, the six superscript ports and the two console handles.
        #expect(ReservedFileNames.devices.count == 30)
        #expect(ReservedFileNames.devices.allSatisfy { $0 == $0.lowercased() })
    }
}
