import Foundation
import Testing
@testable import PrintCore

/// Ported from PrinterSetupTests.cs: setting up a new printer's Wi-Fi (roadmap 4.17) on a made-up Wi-Fi (`DemoWifi`; this
/// Mac's is never read or changed by a test): which networks are a printer's, that looking changes nothing, that the printer's
/// page is only a private address it was given, and that the guide always says how to go back. Adapted: a sandboxed app
/// doesn't join networks (PLAN, "Mac differences"), so every network is joined by the person in macOS's Wi-Fi menu and the
/// guide waits to see it, as Windows' secured networks are (A_secured_network_is_joined_in_windows_own_list_never_here is
/// aSetupNetworkIsJoinedInTheWifiMenuNeverHere); going back is the person's too, the guide waiting to see the Mac on its
/// network again (An_open_setup_network_is_joined_on_the_click_its_page_found_and_done_goes_home is
/// itsPageIsFoundAndDoneWaitsForTheMacToGoHome; A_network_never_joined_goes_back_by_itself_and_says_so is
/// aNetworkNeverJoinedSaysSo; A_pc_that_wasnt_on_wifi_leaves_the_printers_network_again is
/// aMacThatWasntOnWifiIsToldToLeaveThePrintersNetwork). Time is the guide's `pause`, which the tests make instant. Windows
/// only: Only_an_open_network_gets_a_profile_and_it_holds_no_key (Windows' temporary profile), The_palette_offers_the_guide
/// (the Mac app's File menu has it).
struct PrinterSetupTests {
    private static func net(_ name: String, secured: Bool = true) -> WifiNetwork { DemoWifi.net(name, 50, secured: secured) }

    @Test(arguments: [
        ("HP-Setup>5c-DeskJet 4155e", "HP", SetupNetworkKind.setup),
        ("HP-Print-2A-Officejet Pro 8710", "HP", .direct),
        ("DIRECT-4F-HP M234 LaserJet", "HP", .direct),
        ("DIRECT-7A-EPSON-ET-2850 Series", "Epson", .direct),
        ("EPSON123ABC", "Epson", .setup),
        ("Canon_ij_A1B2", "Canon", .setup),
        ("SETUP-9C3F", "Brother", .setup),
        ("DIRECT-xyHL-L2350DW_BRa1b2", "Brother", .direct),
        ("DIRECT-12-Xerox B230", "Xerox", .direct),
    ])
    func aPrintersNetworkIsKnownByItsMakersName(_ ssid: String, _ maker: String, _ kind: SetupNetworkKind) throws {
        let found = try #require(SetupNetworks.classify(Self.net(ssid)))
        #expect(found.maker == maker)
        #expect(found.kind == kind)
    }

    @Test(arguments: [
        "DIRECT-ab-Galaxy S24", // a phone
        "DIRECT-Roku-123", // a TV
        "DIRECT-3f-[TV] Samsung 7 Series", // a TV naming a printer maker further on
        "DIRECT-a1-Android_HP", // a phone
        "Home Wi-Fi",
        "HPS-Office",
        "",
    ])
    func otherNetworksArent(_ ssid: String) {
        #expect(SetupNetworks.classify(Self.net(ssid)) == nil)
    }

    @Test func setupNetworksComeFirstEachOnceAndNamesAreShownSafely() {
        let weak = DemoWifi.net("HP-Setup>5c-DeskJet", 20, secured: false)
        let strong = DemoWifi.net("HP-Setup>5c-DeskJet", 80, secured: false)
        let found = SetupNetworks.find([DemoWifi.epsonDirect, weak, strong, DemoWifi.phone])
        #expect(found.count == 2)
        #expect(found[0].kind == .setup)
        #expect(found[0].network.signal == 80)
        let hostile = WifiNetwork(ssid: Array("SETUP-\u{202E}evil\r\n".utf8) + [0xFF, 0xFE], signal: 50, secured: false)
        #expect(hostile.name == "SETUP-evil ��")
        #expect(SetupNetworks.show([UInt8](repeating: 0, count: 64)).isEmpty)
    }

    @Test(arguments: [
        ("192.168.223.1", "http://192.168.223.1/"),
        ("10.0.0.1", "http://10.0.0.1/"),
        ("172.16.4.1", "http://172.16.4.1/"),
        ("169.254.1.1", "http://169.254.1.1/"),
        ("8.8.8.8", nil),
        ("172.32.0.1", nil),
        ("192.168.1.255", nil),
        ("fe80::1", nil),
        ("192.168.1.1.5", nil),
        ("192.168.01x.1", nil),
    ] as [(String, String?)])
    func thePrintersPageIsOnlyAPrivateAddress(_ gateway: String, _ page: String?) {
        #expect(SetupNetworks.setupPage(gateway)?.absoluteString == page)
    }

    @Test func lookingChangesNothing() async {
        let wifi = DemoWifi()
        let guide = PrinterSetupGuide(wifi, pause: Self.instant)
        await guide.look()
        let state = await guide.state
        #expect(state.step == .choose)
        #expect(state.candidates.map(\.maker) == ["HP", "Epson"])
        #expect(wifi.calls == ["scan"])
        #expect(wifi.current.isOn(DemoWifi.home))
        #expect(!state.isAway)
    }

    @Test func aSetupNetworkIsJoinedInTheWifiMenuNeverHere() async {
        let wifi = DemoWifi()
        let seen = Seen()
        let guide = PrinterSetupGuide(wifi, pause: Self.instant, onChange: seen.add)
        await guide.look()
        let epson = await guide.state.candidates[1]
        wifi.personJoins = DemoWifi.epsonDirect // the person, in the Wi-Fi menu, once asked
        await guide.connect(epson)
        let told = seen.all.first { $0.step == .inMenu }
        #expect(told != nil)
        #expect(told?.problem?.contains("DIRECT-7A-EPSON") == true)
        let state = await guide.state
        #expect(state.step == .onPrinter)
        #expect(state.page?.absoluteString == "http://192.168.223.1/")
        #expect(state.isAway)
        #expect(!wifi.calls.contains { $0.hasPrefix("join") }) // nothing joined it here
    }

    @Test func itsPageIsFoundAndDoneWaitsForTheMacToGoHome() async {
        let wifi = DemoWifi()
        let guide = PrinterSetupGuide(wifi, pause: Self.instant)
        await guide.look()
        let hp = await guide.state.candidates[0]
        wifi.personJoins = hp.network
        await guide.connect(hp)
        #expect(await guide.state.step == .onPrinter)
        wifi.personJoins = DemoWifi.home // back in the Wi-Fi menu
        await guide.returnHome()
        let state = await guide.state
        #expect(state.step == .back)
        #expect(wifi.current.isOn(DemoWifi.home))
        #expect(state.homeName == "Home Wi-Fi")
        #expect(state.page == nil)
        #expect(wifi.calls == ["scan"])
    }

    @Test func aNetworkNeverJoinedSaysSo() async {
        let wifi = DemoWifi()
        let guide = PrinterSetupGuide(wifi, pause: Self.instant)
        await guide.look()
        await guide.connect(await guide.state.candidates[0])
        let state = await guide.state
        #expect(state.step == .back) // never left: already home
        #expect(state.problem == SetupText.notJoined)
    }

    @Test func whenItCantGoBackItSaysHowAndChecksAgain() async {
        let wifi = DemoWifi()
        let guide = PrinterSetupGuide(wifi, pause: Self.instant)
        await guide.look()
        let hp = await guide.state.candidates[0]
        wifi.personJoins = hp.network
        await guide.connect(hp)
        await guide.returnHome() // the person doesn't go back
        var state = await guide.state
        #expect(state.step == .couldNotReturn)
        #expect(state.problem == SetupText.couldNotReturn("Home Wi-Fi"))
        #expect(state.isAway)
        wifi.personJoins = DemoWifi.home
        await guide.checkBack()
        state = await guide.state
        #expect(state.step == .back)
    }

    @Test func aMacThatWasntOnWifiIsToldToLeaveThePrintersNetwork() async {
        let wifi = DemoWifi()
        wifi.current = WifiNow(hasAdapter: true, ssid: nil)
        let guide = PrinterSetupGuide(wifi, pause: Self.instant)
        await guide.look()
        let hp = await guide.state.candidates[0]
        wifi.personJoins = hp.network
        await guide.connect(hp)
        await guide.returnHome()
        let state = await guide.state
        #expect(state.step == .back)
        #expect(state.problem == SetupText.leavePrinter)
    }

    @Test func cancellingAJoinGoesBack() async {
        let wifi = DemoWifi()
        let guide = PrinterSetupGuide(wifi, pause: { _ in try await Task.sleep(for: .milliseconds(5)) })
        await guide.look()
        let epson = await guide.state.candidates[1]
        let connecting = Task { await guide.connect(epson) }
        for _ in 0..<400 where await guide.state.step != .inMenu { try? await Task.sleep(for: .milliseconds(5)) }
        connecting.cancel() // the window closing does this
        await connecting.value
        let state = await guide.state
        #expect(state.step == .back)
        #expect(!state.isAway)
        #expect(wifi.current.isOn(DemoWifi.home))
    }

    @Test func noWifiAndLocationOffSayWhatToDo() async {
        let noAdapter = DemoWifi()
        noAdapter.noAdapter = true
        let none = PrinterSetupGuide(noAdapter, pause: Self.instant)
        await none.look()
        #expect(await none.state.step == .noWifi)
        #expect(await none.state.problem == SetupText.noWifi)
        let locationOff = DemoWifi()
        locationOff.locationOff = true
        let off = PrinterSetupGuide(locationOff, pause: Self.instant)
        await off.look()
        #expect(await off.state.step == .locationOff)
        #expect(await off.state.problem == SetupText.locationOff)
        let wifi = DemoWifi()
        wifi.inRange.removeAll { SetupNetworks.classify($0) != nil }
        let empty = PrinterSetupGuide(wifi, pause: Self.instant)
        await empty.look()
        #expect(await empty.state.step == .choose)
        #expect(await empty.state.problem == SetupText.noneFound)
    }

    /// Windows' PrinterSetupViewModel.MayClose (no Windows test): the window doesn't close while the Mac is on the printer's
    /// network unsaid; it says how to go back, and the next Close closes. Mac only.
    @Test func closingOnThePrintersNetworkSaysHowToGoBackThenTheNextCloseCloses() async {
        let wifi = DemoWifi()
        let guide = PrinterSetupGuide(wifi, pause: Self.instant)
        await guide.look()
        var home = SetupClosing()
        let atHome = home.asked(await guide.state)
        #expect(atHome == .close) // home: closes at once
        let hp = await guide.state.candidates[0]
        wifi.personJoins = hp.network
        await guide.connect(hp)
        let away = await guide.state
        #expect(away.step == .onPrinter)
        var closing = SetupClosing()
        let first = closing.asked(away)
        let again = closing.asked(away) // a second click while going back
        #expect(first == .goBackFirst)
        #expect(again == .wait)
        await guide.returnOnClose() // no wait: says how at once
        let state = await guide.state
        #expect(state.step == .couldNotReturn)
        #expect(state.problem == SetupText.couldNotReturn("Home Wi-Fi"))
        let closesNow = closing.wentBack(state)
        #expect(!closesNow) // stays open saying how
        let next = closing.asked(state)
        #expect(next == .close)
    }

    @Test func closingOnceBackOrAfterLeavingSaysNothingMoreOrHowToLeave() async {
        let wifi = DemoWifi()
        let guide = PrinterSetupGuide(wifi, pause: Self.instant)
        await guide.look()
        let hp = await guide.state.candidates[0]
        wifi.personJoins = hp.network
        await guide.connect(hp)
        var closing = SetupClosing()
        let first = closing.asked(await guide.state)
        #expect(first == .goBackFirst)
        wifi.current = WifiNow(hasAdapter: true, ssid: DemoWifi.home.ssid) // the person went back before closing
        await guide.returnOnClose()
        let back = await guide.state
        #expect(back.step == .back)
        let closesNow = closing.wentBack(back)
        #expect(closesNow)

        let none = DemoWifi()
        none.current = WifiNow(hasAdapter: true, ssid: nil)
        let off = PrinterSetupGuide(none, pause: Self.instant)
        await off.look()
        let printer = await off.state.candidates[0]
        none.personJoins = printer.network
        await off.connect(printer)
        var leaving = SetupClosing()
        let asked = leaving.asked(await off.state)
        #expect(asked == .goBackFirst)
        await off.returnOnClose()
        let told = await off.state
        #expect(told.problem == SetupText.leavePrinter)
        let leftNow = leaving.wentBack(told)
        #expect(!leftNow) // told how to leave the printer's network: stays open
        let next = leaving.asked(told)
        #expect(next == .close)
    }

    @Test func theNewPrinterIsOneThatWasntListedBeforeTheMakersFirst() {
        let before: Set<String> = ["a", "b"]
        #expect(PrinterSetupGuide.foundPrinter([("a", "Old laser"), ("b", "Old inkjet")], before: before, maker: "HP") == nil)
        #expect(PrinterSetupGuide.foundPrinter([("a", "Old laser"), ("c", "Neighbour's Canon"), ("d", "HP DeskJet 4155e")], before: before, maker: "HP")?.id == "d")
        #expect(PrinterSetupGuide.foundPrinter([("c", "Neighbour's Canon")], before: before, maker: "HP")?.id == "c")
    }

    private static let instant: @Sendable (Duration) async throws -> Void = { _ in try Task.checkCancellation() }

    /// The states the guide went through.
    private final class Seen: @unchecked Sendable {
        private let lock = NSLock()
        private var states: [SetupState] = []

        var all: [SetupState] { lock.withLock { states } }
        @Sendable func add(_ state: SetupState) { lock.withLock { states.append(state) } }
    }
}
