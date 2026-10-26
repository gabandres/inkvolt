import AppKit
import Observation
import PrintCore
import PrintMac
import SwiftUI

/// Add a printer (the Windows app's `AddPrinterViewModel`): searches this Mac's network as soon as it opens (printers found
/// show as they're identified, those already listed marked so), puts back printers removed earlier, points a USB printer at
/// Printers & Scanners, and takes an address (IP, name, or an ipp:// / http://host:port URL) as the last resort.
@MainActor @Observable
final class AddPrinterModel {
    private(set) var found: [FoundPrinter] = []
    private(set) var isSearching = false
    /// 0 to 1: the share of addresses asked.
    private(set) var progress = 0.0
    /// What the search is doing, or what it found.
    private(set) var status = ""
    /// The search found nothing to add: say what may hide a printer.
    private(set) var nothingFound = false
    var address = ""
    private(set) var addressError: String?
    private(set) var isAddingAddress = false

    @ObservationIgnored private let app: AppModel
    @ObservationIgnored private var search: Task<Void, Never>?

    init(app: AppModel) { self.app = app }

    /// Lists printers removed earlier that are on the network, then starts the search.
    func start() {
        for f in app.removedNearby().compactMap(AddPrinter.removed) { AddPrinter.insert(f, into: &found) }
        searchAgain()
    }

    func searchAgain() {
        guard !isSearching else { return }
        isSearching = true
        nothingFound = false
        progress = 0
        status = AddPrinterText.looking
        let app = app
        let skip = Set(found.map(\.host))
        search = Task {
            do {
                let total = try await AddPrinter.run(skip: skip, search: { found, progress in
                    try await app.searchNetwork(found: found, progress: progress)
                }, identify: { host in
                    await app.identify(host)
                }, progress: { p in
                    Task { @MainActor in self.searched(p) }
                }, checking: {
                    Task { @MainActor in self.status = AddPrinterText.checking }
                }, found: { f in
                    Task { @MainActor in self.insert(f) }
                })
                await Task.yield() // the last printers found are queued: count them in
                done(AddPrinterText.done(total: total, found: found))
            } catch is CancellationError {
                done(AddPrinterText.stopped)
            } catch {
                done(AddPrinterText.failed)
            }
        }
    }

    func stop() { search?.cancel() }

    private func searched(_ p: SearchProgress) {
        guard isSearching, p.total > 0 else { return }
        progress = Double(p.checked) / Double(p.total)
        status = AddPrinterText.looking(p)
    }

    private func insert(_ f: FoundPrinter) {
        guard !found.contains(where: { $0.host.caseInsensitiveCompare(f.host) == .orderedSame }) else { return }
        AddPrinter.insert(f, into: &found)
    }

    private func done(_ text: String) {
        isSearching = false
        progress = 0
        status = text
        nothingFound = text != AddPrinterText.stopped && AddPrinterText.nothingFound(found)
    }

    func add(_ f: FoundPrinter) {
        guard let i = found.firstIndex(where: { $0.id == f.id }), found[i].state == .canAdd else { return }
        let p: PrinterModel? = if let d = f.removed { app.addBack(d) } else if let probe = f.probe { app.add(probe, host: f.host) } else { nil }
        guard let p else {
            found[i].error = "Couldn't add it: it isn't on the network now."
            return
        }
        found[i].state = .added
        found[i].printerId = p.id
        found[i].error = nil
    }

    /// Shows a listed (or just added) printer in the main window.
    func show(_ f: FoundPrinter) {
        guard let id = f.printerId, app.printers.contains(where: { $0.id == id }) else { return }
        app.selectedID = id
        app.isAddingPrinter = false
    }

    var canAddAddress: Bool { !address.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty && !isAddingAddress }

    func addAddress() {
        addressError = nil
        let a = PrinterAddress.parse(address)
        if let error = a.error {
            addressError = error
            return
        }
        guard let host = a.host else { return }
        isAddingAddress = true
        Task {
            defer { isAddingAddress = false }
            guard let f = await app.identify(host, ipp: a.ipp), let probe = f.probe else {
                addressError = AddPrinterText.noAnswer(host)
                return
            }
            if let listed = app.listed(probe, host) { app.selectedID = listed.id } else { app.add(probe, host: host) }
            app.isAddingPrinter = false
        }
    }
}

/// The Add a printer sheet over the main window.
struct AddPrinterSheet: View {
    @Environment(AppModel.self) private var app
    @State private var model: AddPrinterModel?

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            if let model { AddPrinterContent(model: model) }
            Divider()
            HStack {
                Spacer()
                Button("Done") { app.isAddingPrinter = false }.keyboardShortcut(.cancelAction)
            }
            .padding(14)
        }
        .frame(width: 560)
        .frame(minHeight: 520)
        .onAppear {
            guard model == nil else { return }
            let m = AddPrinterModel(app: app)
            model = m
            m.start()
        }
        .onDisappear { model?.stop() }
    }
}

private struct AddPrinterContent: View {
    @Bindable var model: AddPrinterModel

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 18) {
                VStack(alignment: .leading, spacing: 4) {
                    Text("Add a Printer").font(.title2.weight(.semibold))
                    Text("Printers on your network show up in your list by themselves. Not seeing yours? Try these.")
                        .foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
                }
                network
                cable
                byAddress
            }
            .padding(20)
        }
    }

    private var network: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack(spacing: 8) {
                Label("On your network", systemImage: "wifi").font(.headline)
                Spacer()
                if model.isSearching {
                    Button("Stop") { model.stop() }.accessibilityLabel("Stop searching")
                } else {
                    Button("Search Again") { model.searchAgain() }
                }
            }
            if model.isSearching {
                ProgressView(value: model.progress).accessibilityLabel("Search progress")
            }
            Text(model.status).font(.callout).foregroundStyle(.secondary)
            ForEach(model.found) { f in FoundRow(found: f, model: model) }
            if model.nothingFound {
                Label("A printer that's off or asleep, on another network (a guest Wi-Fi, another floor), or behind a VPN or firewall can't be found this way. Wake it up and search again, or enter its address below.",
                      systemImage: "info.circle")
                    .font(.callout).fixedSize(horizontal: false, vertical: true)
            }
            Text("Only devices on this Mac's own network are asked whether they print. Nothing is sent anywhere else.")
                .font(.caption).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
        }
    }

    private var cable: some View {
        VStack(alignment: .leading, spacing: 6) {
            Label("Connected with a cable?", systemImage: "cable.connector").font(.headline)
            Text("Plug it in and turn it on, then add it in Printers & Scanners in System Settings.")
                .font(.callout).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
            Button("Open Printers & Scanners") { NSWorkspace.shared.open(SystemSettings.printers) }
        }
    }

    private var byAddress: some View {
        VStack(alignment: .leading, spacing: 6) {
            Label("Know its address?", systemImage: "number").font(.headline)
            HStack {
                TextField("IP address, name or printer URL", text: $model.address)
                    .textFieldStyle(.roundedBorder)
                    .onSubmit { if model.canAddAddress { model.addAddress() } }
                if model.isAddingAddress {
                    ProgressView().controlSize(.small).accessibilityLabel("Adding")
                } else {
                    Button("Add") { model.addAddress() }.disabled(!model.canAddAddress).accessibilityLabel("Add the printer at this address")
                }
            }
            if let error = model.addressError {
                Text(error).font(.callout).foregroundStyle(.red).fixedSize(horizontal: false, vertical: true)
            }
            Text("It's on the printer's screen (network or Wi-Fi settings) or on a network report it prints. For example 192.168.1.40, printer.local or ipp://printer.local/ipp/print.")
                .font(.caption).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
        }
    }
}

private struct FoundRow: View {
    let found: FoundPrinter
    let model: AddPrinterModel

    var body: some View {
        HStack(alignment: .center, spacing: 10) {
            Image(systemName: "printer").foregroundStyle(.secondary).accessibilityHidden(true)
            VStack(alignment: .leading, spacing: 2) {
                Text(found.name).lineLimit(1).help(found.name)
                Text(found.detail).font(.caption).foregroundStyle(.secondary).lineLimit(1)
                if let error = found.error { Text(error).font(.caption).foregroundStyle(.red) }
            }
            Spacer()
            switch found.state {
            case .canAdd:
                Button("Add") { model.add(found) }.accessibilityLabel("Add \(found.name)")
            case .adding:
                ProgressView().controlSize(.small).accessibilityLabel("Adding")
            case .added, .listed:
                Label("In your list", systemImage: "checkmark").font(.caption).foregroundStyle(.secondary)
                Button("Show") { model.show(found) }.accessibilityLabel("Show \(found.name) in the list")
            }
        }
        .padding(.vertical, 4)
    }
}
