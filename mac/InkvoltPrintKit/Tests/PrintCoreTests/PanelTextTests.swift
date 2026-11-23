import Foundation
import Testing
@testable import PrintCore

/// The front panel's text in the printer's status: the Printer MIB's prtConsoleDisplayBufferText lines, IPP's
/// `printer-state-message`, LEDM's status text; shown only when it says more than the status line, as one clean, short
/// line. Ported from PanelTextTests.cs.
struct PanelTextTests {
    private static func agent(_ name: String, _ edit: (String) -> String = { $0 }) throws -> SnmpAgent {
        SnmpAgent(try SnmpAgent.parseWalk(edit(try Fixtures.text("snmp-demo/\(name)"))))
    }

    private static func status(_ message: String, _ panel: String?) -> PrinterStatus {
        PrinterStatus(code: "ready", message: message, severity: .info, alerts: [], panelText: panel)
    }

    @Test(arguments: [
        ("Ready", "Order magenta toner", "Order magenta toner"),
        ("Ready", "Ready", nil), // says nothing more
        ("Ready", "ready.", nil),
        ("Ready", "Idle.", nil), // a plain "Idle" under the app's own word for it
        ("Ready", "Prêt", nil), // the same in the panel's language
        ("Ready", "Bereit.", nil),
        ("Ready", "Lista para imprimir", "Lista para imprimir"), // three words: more than a state's name
        ("Ready", "Tray 2", "Tray 2"), // a figure: not a state's name
        ("Sleeping", "Sleep mode is on.", "Sleep mode is on"),
        ("Ready", "  ", nil),
        ("Ready", nil, nil),
        ("Ready", "Tray 2\r\nLoad A4\tplain", "Tray 2 Load A4 plain"), // one line
        ("Ready", "\u{202E}regnad\u{202C} the tray", "regnad the tray"), // no right-to-left override turning it round
    ] as [(String, String?, String?)])
    func thePanelsTextShowsWhenItSaysMoreThanTheStatus(_ message: String, _ panel: String?, _ shown: String?) {
        #expect(Self.status(message, panel).panelNote == shown)
    }

    @Test func aLongPanelTextIsCutToOneLine() throws {
        let note = try #require(Self.status("Ready", String(repeating: "x", count: 10_000)).panelNote)
        #expect(note.count <= PrinterStatus.maxPanelText, "\(note.count)")
        #expect(note.hasSuffix("…"))
    }

    @Test func snmpReadsThePanelsLines() async throws {
        let mfp = try #require(try await SnmpPrinterClient.probe(transport: try Self.agent("color-mfp.txt"), host: "192.0.2.15"))
        let status = try await mfp.status()
        #expect(status.panelText == "Ready · Order magenta toner")
        #expect(status.panelNote == "Ready · Order magenta toner")

        let laser = try #require(try await SnmpPrinterClient.probe(transport: try Self.agent("workgroup-laser.txt"), host: "192.0.2.14"))
        let ready = try await laser.status()
        #expect(ready.panelText == "Ready") // the panel says "Ready" too
        #expect(ready.panelNote == nil)
    }

    @Test func aPanelOfHundredsOfLinesKeepsTheFirstFewWithWords() async throws {
        let lines = (1...300).map { i in ".1.3.6.1.2.1.43.16.5.1.2.1.\(i) = STRING: \"\(i % 2 == 0 ? "Line \(i)" : " ")\"\n" }.joined()
        let agent = try Self.agent("workgroup-laser.txt") {
            $0.replacingOccurrences(of: ".1.3.6.1.2.1.43.16.5.1.2.1.1 = STRING: \"Ready\"\r\n", with: lines)
                .replacingOccurrences(of: ".1.3.6.1.2.1.43.16.5.1.2.1.1 = STRING: \"Ready\"\n", with: lines)
        }
        let printer = try #require(try await SnmpPrinterClient.probe(transport: agent, host: "192.0.2.14"))
        let reading = try await printer.read()
        #expect(reading.panel.count == SnmpReading.maxPanelLines)
        #expect(reading.panel.first == "Line 2") // the blank lines are left out
    }

    @Test func ippsStateMessageIsThePanelsText() throws {
        let r = try IppCodec.decode(IppCodec.encodeResponse(status: 0, requestId: 1,
                                                            IppText.parse("printer-state enum 3\nprinter-state-message text Ready to print, tray 1 low")))
        let status = IppClient.toStatus(r)
        #expect(status.panelText == "Ready to print, tray 1 low")
        #expect(status.panelNote == nil) // already the status line
    }

    @Test func ledmsStatusTextIsThePanelsWhenTheStatusIsInTheAppsWords() throws {
        let status = LedmParsers.parseStatus(try DeviceXml.load(Fixtures.data("m234dw/DevMgmt_ProductStatusDyn.xml"))) // inPowerSave, "Sleep mode is on."
        #expect(status.panelText == "Sleep mode is on.")
        #expect(status.panelNote == "Sleep mode is on")
    }

    @Test func theMonitorShowsThePanelsText() async throws {
        let network = Demo.network(fixtures: Fixtures.root)
        let laser = try #require(Demo.state().printers.first { $0.uuid == Demo.uuid })
        let m = PrinterMonitor(id: laser.uuid, name: laser.name, target: laser.target,
                               recipe: PrinterRecipe(transport: { _, _ in network.http }, snmp: network.snmp), accepted: { [] },
                               acceptUuids: { _ in }, retryDelay: .milliseconds(50), fallbackRefresh: .milliseconds(200), onEvent: { _ in })
        let run = Task { await m.run() }
        defer { run.cancel() }
        var panel: String?
        for _ in 0..<1000 {
            panel = await m.view.statusPanel
            if panel != nil { break }
            try await Task.sleep(for: .milliseconds(10))
        }
        #expect(panel == "Sleep mode is on")
    }
}
