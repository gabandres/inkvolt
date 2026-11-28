import AppKit
import Observation
import PrintCore
import PrintMac
import SwiftUI

/// The page of a USB printer or scanner that needs its driver (the Windows app's `NeedsDriverViewModel`): what's wrong, what to
/// do, and Get the driver, which finds the maker's own download for the model and this Mac and opens its link in the browser
/// (the Mac App Store copy never downloads or runs an installer), then watches for the device becoming usable. Kept per device
/// by the app, so its state lasts while another printer is selected.
@MainActor
@Observable
final class NeedsDriverModel {
    private(set) var device: NeedsDriverPrinter
    /// Plugged in now (it was in the last read of the Mac's USB devices).
    var present = true
    /// What it's doing now ("Looking on Epson's website…"), nil when idle.
    private(set) var progress: String?
    /// The download found, offered as the maker's link.
    private(set) var offered: DriverOffer?
    /// What the last step said.
    private(set) var result: String?
    /// The link was opened: the device is watched for.
    private(set) var isWaiting = false
    /// Found working after the link (the app moves to it).
    private(set) var isFound = false
    /// The maker's page for the model, once a lookup found it.
    private(set) var modelPage: URL?
    @ObservationIgnored private weak var app: AppModel?
    @ObservationIgnored private var watching: Task<Void, Never>?

    init(_ device: NeedsDriverPrinter, app: AppModel) {
        self.device = device
        self.app = app
    }

    func update(_ device: NeedsDriverPrinter) { if device != self.device { self.device = device } }

    var getter: (any DriverGetter)? { app?.drivers }
    var canGetDriver: Bool { getter?.looksUp(device) == true }
    var steps: [DriverStep] { DriverSteps.for(device, present: present, getDriver: canGetDriver) }

    func openMakerPage() { open(DriverHelp.page(for: device, modelPage: modelPage)) }
    func openPrinters() { open(SystemSettings.printers) }

    /// Opens a page in the browser (System Settings for Printers & Scanners); demo mode and `--report` open nothing.
    @discardableResult
    private func open(_ url: URL) -> Bool {
        guard !device.isMadeUp, !(app?.isDemo ?? true) else {
            result = NeedsDriverText.demo(device)
            return false
        }
        guard !Report.isRunning else { return true } // the report says what would open; nothing does
        return NSWorkspace.shared.open(url)
    }

    func getDriver() async {
        guard progress == nil, let getter else { return }
        result = nil
        offered = nil
        progress = DriverText.looking(device)
        let found = await getter.find(device)
        progress = nil
        modelPage = found.page ?? found.offer?.page ?? modelPage
        guard let offer = found.offer else {
            NSLog("%@", "[\(device.name)] get the driver: \(DriverText.englishNoOffer(device, found))")
            result = DriverText.unavailable(device, found)
            return
        }
        NSLog("%@", "[\(device.name)] driver found (link only): \(DriverText.englishOffer(offer))")
        offered = offer
    }

    /// Download it from the maker: the maker's link (or its licence's page) in the browser, then the device watched for.
    func openLink() {
        guard let offer = offered, let getter else { return }
        guard let link = getter.linkFor(offer, device) else {
            result = DriverText.otherSite(device)
            return
        }
        guard open(link) else { return }
        NSLog("%@", "[\(device.name)] driver link opened in the browser (\(link.host ?? "")); watching for the device")
        result = DriverText.waiting
        isWaiting = true
        watch()
    }

    /// Every 3 s while waiting (and at once when a USB device comes or goes): found once it's plugged in and works.
    private func watch() {
        watching?.cancel()
        watching = Task { [weak self] in
            while !Task.isCancelled, (try? await Task.sleep(for: .seconds(3))) != nil {
                guard let self, self.isWaiting else { return }
                self.check()
            }
        }
    }

    /// One look: found when the device is plugged in and usable (DeviceState), never when it merely went (unplugged).
    func check() {
        guard isWaiting, let app else { return }
        if DeviceState.found(app.deviceNow(device)) { found() }
    }

    func lookAgain() async {
        guard progress == nil, let app else { return }
        progress = DriverText.lookingAgain
        try? await Task.sleep(for: .milliseconds(400))
        progress = nil
        if DeviceState.found(app.deviceNow(device)) { found() } else { result = DriverText.notYet(device) }
    }

    private func found() {
        isWaiting = false
        watching?.cancel()
        offered = nil
        isFound = true
        result = DriverText.foundIt(device)
        NSLog("%@", "[\(device.name)] driver installed by the user: found")
        app?.driverFound(device)
    }

    func stop() { watching?.cancel() }
}

/// The page itself: the name, what's wrong, What to do, Get the driver, Other ways.
struct NeedsDriverPane: View {
    let device: NeedsDriverPrinter
    @Environment(AppModel.self) private var app

    var body: some View {
        let page = app.driverPage(device)
        ScrollView {
            VStack(alignment: .leading, spacing: 16) {
                VStack(alignment: .leading, spacing: 6) {
                    Label(device.name, systemImage: device.isScanner ? "scanner" : "printer")
                        .font(.title2.weight(.semibold))
                    Text(NeedsDriverText.headline(device)).font(.headline)
                    Text(NeedsDriverText.listStatus(device)).foregroundStyle(.secondary)
                    Text(NeedsDriverText.whyMakersDriver(device)).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
                }
                if device.isMadeUp { Text(NeedsDriverText.demo(device)).font(.callout).foregroundStyle(.orange) }
                GroupBox {
                    VStack(alignment: .leading, spacing: 10) {
                        ForEach(page.steps, id: \.number) { step in
                            HStack(alignment: .firstTextBaseline, spacing: 8) {
                                Text(step.number.formatted()).font(.headline).frame(minWidth: 18, alignment: .trailing)
                                VStack(alignment: .leading, spacing: 6) {
                                    Text(step.text).fixedSize(horizontal: false, vertical: true)
                                    if step.button == .main {
                                        Button(NeedsDriverText.makerButton(device)) { page.openMakerPage() }.buttonStyle(.borderedProminent)
                                    } else if step.button == .plain {
                                        Button(NeedsDriverText.makerButton(device)) { page.openMakerPage() }
                                    }
                                }
                            }
                            .accessibilityElement(children: .combine)
                        }
                    }
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .padding(6)
                } label: { Text(NeedsDriverText.stepsTitle) }
                if page.canGetDriver { GetDriverBox(page: page) }
                if let result = page.result, !page.canGetDriver {
                    Text(result).font(.callout).foregroundStyle(.secondary)
                }
                GroupBox {
                    VStack(alignment: .leading, spacing: 6) {
                        Button(NeedsDriverText.printersButton) { page.openPrinters() }
                        Text(NeedsDriverText.printersNote).font(.callout).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
                    }
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .padding(6)
                } label: { Text(NeedsDriverText.otherWaysTitle) }
            }
            .padding(20)
            .frame(maxWidth: 640, alignment: .leading)
        }
        .navigationTitle(device.name)
    }
}

/// Get the driver: the button, what it does, what it found and its link, and the watch for the device.
struct GetDriverBox: View {
    let page: NeedsDriverModel

    var body: some View {
        let device = page.device
        GroupBox {
            VStack(alignment: .leading, spacing: 8) {
                Text(DriverText.note(device)).font(.callout).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
                if let offer = page.offered {
                    Text(DriverText.foundTitle(device)).font(.headline)
                    Text(DriverText.offerFacts(offer)).font(.callout).textSelection(.enabled)
                    if offer.licence != nil { Text(DriverText.licenceLinkNote(device)).font(.callout).foregroundStyle(.secondary) }
                    Button(DriverText.openLinkButton(device)) { page.openLink() }.buttonStyle(.borderedProminent)
                    Text(DriverText.openLinkNote(device)).font(.callout).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
                } else if !page.isWaiting && !page.isFound {
                    Button(DriverText.button) { Task { await page.getDriver() } }
                        .buttonStyle(.borderedProminent)
                        .disabled(page.progress != nil)
                }
                if let progress = page.progress {
                    HStack(spacing: 6) {
                        ProgressView().controlSize(.small)
                        Text(progress).font(.callout)
                    }
                }
                if let result = page.result { Text(result).font(.callout).fixedSize(horizontal: false, vertical: true) }
                if page.isWaiting {
                    Button(DriverText.lookAgainButton) { Task { await page.lookAgain() } }.disabled(page.progress != nil)
                }
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            .padding(6)
        } label: { Text(DriverText.button) }
    }
}

/// A printer or scanner that needs its driver, in the sidebar's list of them.
struct NeedsDriverRow: View {
    let device: NeedsDriverPrinter

    var body: some View {
        HStack(alignment: .firstTextBaseline, spacing: 8) {
            Image(systemName: device.isScanner ? "scanner" : "printer").foregroundStyle(.orange).frame(width: 12).accessibilityHidden(true)
            VStack(alignment: .leading, spacing: 2) {
                Text(device.name).lineLimit(1)
                Text(NeedsDriverText.listStatus(device)).font(.caption).foregroundStyle(.secondary).lineLimit(2)
            }
        }
        .padding(.vertical, 2)
        .accessibilityElement(children: .combine)
    }
}

/// The line a printer's page shows when its scanner part is plugged in without its driver (an all-in-one whose printer part
/// prints), with Get the driver: Windows' Scan tab line.
struct NeedsDriverLine: View {
    let device: NeedsDriverPrinter
    @Environment(AppModel.self) private var app

    var body: some View {
        HStack(alignment: .firstTextBaseline, spacing: 8) {
            Image(systemName: "exclamationmark.triangle").foregroundStyle(.orange).accessibilityHidden(true)
            Text(NeedsDriverText.scanTabLine(device)).fixedSize(horizontal: false, vertical: true)
            Spacer(minLength: 8)
            Button(DriverText.button) { app.selectedID = device.id }
        }
        .padding(10)
        .background(.orange.opacity(0.1), in: .rect(cornerRadius: 8))
    }
}
