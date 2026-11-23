import Foundation
import PrintCore
import PrintMac

extension Report {
    /// `--setup-wifi` (roadmap 4.17). With `--demo`: File › Set Up a New Printer's Wi-Fi… on the made-up Wi-Fi, driven
    /// through each step (the networks found, the made-up person joining HP's in the Wi-Fi menu, the page, a Close that stays
    /// open saying how to go back, Done, back), the window closed after. Without: this Mac's Wi-Fi as the guide would read it
    /// (location access, whether a scan works and gives names, a gateway), with no network's name or address and nothing
    /// asked or joined.
    static func setupWifiCheck(_ model: AppModel) async -> [String] {
        guard model.isDemo else { return await CoreWifi.reportLines() }
        let setup = PrinterSetupWindow.show(model)
        var lines: [String] = []
        func say(_ what: String) async {
            await setup.settle()
            try? await Task.sleep(for: .milliseconds(200)) // the state stream's last value
            let s = setup.state
            lines.append("setup-wifi \(what): \(s.step)\(s.problem.map { " (\($0))" } ?? "")")
        }
        await say("look")
        lines.append("setup-wifi networks: " + setup.state.candidates.map { "\($0.network.name) [\(PrinterSetupView.describe($0))]" }.joined(separator: "; "))
        guard let hp = setup.state.candidates.first else { return lines + ["setup-wifi: no candidate"] }
        setup.use(hp)
        await say("use \(hp.network.name)")
        lines.append("setup-wifi page: \(setup.state.page?.absoluteString ?? "none"), away \(setup.state.isAway)")
        let closesNow = setup.mayClose { NSLog("setup-wifi: closed while on the printer's network") }
        await say("close while away (closes at once: \(closesNow))")
        setup.done()
        await say("done")
        lines.append("setup-wifi home: \(setup.state.homeName ?? "none"), away \(setup.state.isAway)")
        PrinterSetupWindow.closeForReport()
        return lines
    }
}
