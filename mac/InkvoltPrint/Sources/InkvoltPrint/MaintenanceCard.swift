import AppKit
import Observation
import PrintCore
import PrintMac
import SwiftUI

/// The printer's maintenance card (the Windows app's `MaintenanceViewModel`): only what the printer advertises (HP's
/// internal pages, cleaning and alignment, IPP Identify-Printer), each confirmed first and sent once.
@MainActor @Observable
final class MaintenanceModel {
    private(set) var options = MaintenanceOptions.none
    private(set) var loaded = false
    private(set) var busy = false
    private(set) var result: MaintenanceResult?
    var asking: MaintenanceAction?
    var askingPassword = false

    @ObservationIgnored private let printer: PrinterModel
    @ObservationIgnored private var retry: MaintenanceAction?

    init(printer: PrinterModel) { self.printer = printer }

    func load() async {
        guard let conn = await printer.connection() else { return }
        options = (try? await MaintenanceClient(conn, userName: NSUserName()).detect()) ?? .none
        loaded = true
    }

    func whyNot(_ a: MaintenanceAction) -> String? {
        MaintenanceAvailability.whyNot(a, online: printer.view.isOnline, status: printer.view.isOnline ? currentStatus : nil, busy: busy)
    }

    private var currentStatus: PrinterStatus {
        let v = printer.view
        return PrinterStatus(code: v.phase == .online ? "ready" : "offline", message: v.statusMessage, severity: v.severity, alerts: v.alerts)
    }

    func run(_ a: MaintenanceAction) async {
        guard let conn = await printer.connection() else {
            result = MaintenanceResult(false, "The printer isn't answering.")
            return
        }
        busy = true
        defer { busy = false }
        if let password = PrinterPasswords.password(for: printer.id) { conn.http.setCredentials(user: "admin", password: password) }
        do {
            result = try await MaintenanceClient(conn, userName: NSUserName()).run(a)
        } catch is LedmAuthRequiredError {
            retry = a
            askingPassword = true
        } catch {
            result = MaintenanceResult(false, "The printer didn't take the request.")
        }
    }

    func usePassword(_ password: String) async {
        PrinterPasswords.set(password, for: printer.id)
        if let a = retry {
            retry = nil
            await run(a)
        }
    }
}

struct MaintenanceCard: View {
    @State private var model: MaintenanceModel
    @State private var password = ""

    init(printer: PrinterModel) { _model = State(initialValue: MaintenanceModel(printer: printer)) }

    var body: some View {
        Group {
            if model.loaded && (!model.options.actions.isEmpty || model.options.supplyPage != nil) {
                VStack(alignment: .leading, spacing: 10) {
                    Text("Maintenance").font(.headline)
                    ForEach(Array(model.options.actions.enumerated()), id: \.offset) { _, a in
                        HStack(alignment: .firstTextBaseline) {
                            VStack(alignment: .leading, spacing: 2) {
                                Text(a.label)
                                Text(model.whyNot(a) ?? a.summary).font(.caption).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
                            }
                            Spacer()
                            Button(a.confirmButton) { model.asking = a }.disabled(model.whyNot(a) != nil)
                        }
                    }
                    if let r = model.result {
                        Label(r.message, systemImage: r.ok ? "checkmark.circle.fill" : "xmark.circle").foregroundStyle(r.ok ? .green : .red)
                    }
                    if let page = model.options.supplyPage {
                        Button("Maintenance Page") { NSWorkspace.shared.open(page) }.buttonStyle(.link)
                    }
                    if let note = model.options.note { Text(note).font(.caption).foregroundStyle(.secondary) }
                }
                .padding(16)
                .frame(maxWidth: .infinity, alignment: .leading)
                .background(.background.secondary, in: .rect(cornerRadius: 10))
            }
        }
        .task { await model.load() }
        .confirmationDialog(model.asking?.label ?? "", isPresented: Binding(get: { model.asking != nil }, set: { if !$0 { model.asking = nil } })) {
            if let a = model.asking { Button(a.confirmButton) { Task { await model.run(a) } } }
        } message: {
            Text(model.asking.map { a in a.uses + (a.printsPage ? "\n\nThe printer needs to be on and free, with plain paper loaded." : "") } ?? "")
        }
        .sheet(isPresented: $model.askingPassword) {
            VStack(alignment: .leading, spacing: 12) {
                Text("The printer asks for its admin password").font(.headline)
                Text("It's the password of the printer's web page. Inkvolt Print keeps it in your keychain and sends it only to this printer, over HTTPS.")
                    .foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
                SecureField("Password", text: $password)
                HStack {
                    Spacer()
                    Button("Cancel", role: .cancel) { model.askingPassword = false }
                    Button("Send") {
                        let p = password
                        password = ""
                        model.askingPassword = false
                        Task { await model.usePassword(p) }
                    }
                    .keyboardShortcut(.defaultAction)
                    .disabled(password.isEmpty)
                }
            }
            .padding(20)
            .frame(width: 420)
        }
    }
}
