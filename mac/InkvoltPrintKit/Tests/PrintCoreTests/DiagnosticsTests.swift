import Foundation
import Testing
@testable import PrintCore

/// The scrubber of reports, exports and recordings. Ported from HelpTests.cs, its two Scrub theories (the report, the log
/// tail and the issue address come with Report a Problem): the same lines, the same results.
struct DiagnosticsTests {
    private static let me = Diagnostics.Identity("jdoe", "JDOE-LAPTOP")

    @Test(arguments: [
        ("Connected to 192.168.1.23:631", "Connected to [ip]:631"),
        ("ipps://192.0.2.10/ipp/print failed", "ipps://[host]/ipp/print failed"),
        ("GET http://HPF0A1B2.local:8080/eSCL/ScannerStatus", "GET http://[host]:8080/eSCL/ScannerStatus"),
        ("resolved NPI1A2B3C.local", "resolved [host].local"),
        ("printer 12345678-1234-4abc-8def-123456789abc added", "printer [uuid] added"),
        ("urn:uuid:12345678-1234-4ABC-8DEF-123456789ABC", "urn:uuid:[uuid]"),
        ("MAC a0:b1:c2:d3:e4:f5 seen", "MAC [mac] seen"),
        ("fe80::1c2b:3a4d:5e6f:7a8b%12 answered", "[ip] answered"),
        ("Serial number: CNB9K12345", "Serial number: [serial]"),
        ("SNMP device TH12A3B456 matched", "SNMP device [id] matched"),
        ("HP OfficeJet Pro 9010 series [A1B2C3]", "HP OfficeJet Pro 9010 series [id]"),
        ("pin 9F86D081884C7D659A2FEAA0C55AD015A3BF4F1B2B0B822CD15D6C15B0F00A08", "pin [hex]"),
        ("mail from jane.doe@example.com", "mail from [email]"),
        (#"Saved C:\Users\jdoe\Documents\Taxes 2026\return.pdf"#, "Saved [path].pdf"),
        (#"Opened \\nas\share\scan.jpg"#, "Opened [path].jpg"),
        (#"Inkvolt Print started (C:\Program Files (x86)\Inkvolt\InkvoltPrint.exe)"#, "Inkvolt Print started ([path].exe)"),
        (#"tried C:\Scans\a.pdf, C:\Scans\b.pdf; gave up"#, "tried [path].pdf, [path].pdf; gave up"),
        (#"at InkvoltPdf.App.MainWindow.OnSave() in Z:\PdfDesk\pdf\src\MainWindow.xaml.cs:line 12"#, "at InkvoltPdf.App.MainWindow.OnSave() in [path].cs:line 12"),
        ("Logged in as JDoe on jdoe-laptop", "Logged in as [user] on [pc]"),
        (#"Opened C:\Users\x\Documents\John Smith tax return.pdf"#, "Opened [path].pdf"),
        (#"Opened \\srv\share\Jane Doe.pdf (2 pages)"#, "Opened [path].pdf (2 pages)"),
        ("No such host is known. (officeprinter.lan:80)", "No such host is known. ([host]:80)"),
        ("Connection refused (printer:9100)", "Connection refused ([host]:9100)"),
        ("OFFICE-PRINTER.CORP:443 timed out", "[host]:443 timed out"),
        ("resolved OfficePrinter.home.arpa, retrying", "resolved [host], retrying"),
        ("found npi7a1b2c and NPI7A1B2C", "found [host] and [host]"),
        ("answered at printer.home.local", "answered at [host].local"),
        ("from ::ffff:192.168.1.5 on port 631", "from [ip] on port 631"),
        ("peer 172.16.5.4 and 8.8.8.8", "peer [ip] and 8.8.8.8"),
        ("SerialNumber=CNB9K12345", "SerialNumber=[serial]"),
        ("Serial number: CNB9K12345, firmware TJP1FN2405AR", "Serial number: [serial], firmware TJP1FN2405AR"),
        ("device CN12345678 and TJP1FN2405AR", "device [id] and [id]"),
        ("device CN1234ABCD, then KMN12345", "device [id], then [id]"),
    ])
    func Scrub_masks_what_identifies_a_person_a_printer_or_a_network(_ line: String, _ expected: String) {
        #expect(Diagnostics.scrub(line, Self.me) == expected)
    }

    @Test(arguments: [
        "12:34:56.789 Scan finished in 4.2 s",
        "HRESULT 0x8007000E (out of memory)",
        "HP LaserJet MFP M234dw: toner 42 %",
        "System.IO.IOException: The process cannot access the file",
        "eSCL 2.63, 300 dpi, A4",
        "Brother MFC-L8900CDW: ready",
        "Firmware: TJP1FN2405AR (2024-08-13)",
        "Firmware revision SAYPRO1N001.2045A",
        "Inkvolt PDF 1.0.7.0 started",
        "Could not load 'System.Text.Json, Version=10.0.12.0'",
        "System.Text.Json.Serialization.JsonException: bad value",
        "at InkvoltPrint.App.ViewModels.ScanViewModel.SaveAsync() in MainWindow.xaml.cs:line 12",
        "settings.json not read; state.json kept",
        "What's New shown for 1.0.7, 1.0.6",
        "2026-10-25T10:00:00 Response status code does not indicate success: 404 (Not Found).",
    ])
    func Scrub_keeps_what_helps_find_the_problem(_ line: String) {
        #expect(Diagnostics.scrub(line, Self.me) == line)
    }
}
