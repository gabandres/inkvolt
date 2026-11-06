import Observation
import PrintCore
import SwiftUI

/// What the SNMP access fields hold (Add a Printer's and the printer's menu's; roadmap 3.2): the community a printer that
/// answers only SNMP is read with (blank: public). The Windows app's `SnmpAccessFields`. Kept in the Keychain with the
/// printer, never in the state file.
@MainActor @Observable
final class SnmpAccessModel {
    var community = ""
    /// Why what was entered can't be used; nil when it can (or nothing was asked yet).
    private(set) var error: String?

    init(_ current: SnmpLogin = .public) {
        community = current.isDefault ? "" : current.community
    }

    /// The login entered, or nil with the reason in `error`.
    func read() -> SnmpLogin? {
        do {
            let login = try SnmpLogin.forCommunity(community)
            error = nil
            return login
        } catch {
            self.error = "\(error)"
            return nil
        }
    }

    func edited() { error = nil }
}

/// The SNMP access fields.
struct SnmpAccessFields: View {
    @Bindable var model: SnmpAccessModel

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            TextField("Community", text: $model.community, prompt: Text("public"))
                .textFieldStyle(.roundedBorder)
                .onChange(of: model.community) { model.edited() }
            Text("Leave it blank for public, the community most printers ship with.")
                .font(.caption).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
            if let error = model.error {
                Text(error).font(.callout).foregroundStyle(.red).fixedSize(horizontal: false, vertical: true)
            }
        }
    }
}

/// The printer's menu › SNMP Access…: for a printer read over SNMP, the login it's read with; Save keeps it and connects
/// again.
struct SnmpAccessSheet: View {
    let printer: PrinterModel
    @State private var model: SnmpAccessModel
    @State private var refused = false
    @Environment(\.dismiss) private var dismiss

    init(printer: PrinterModel) {
        self.printer = printer
        _model = State(initialValue: SnmpAccessModel(printer.snmpLogin))
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text("SNMP Access for \(printer.name)").font(.title3.weight(.semibold))
            Text(SnmpAccessText.explanation)
                .foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
            SnmpAccessFields(model: model)
            if refused {
                Text(SnmpAccessText.keychainRefused).font(.callout).foregroundStyle(.red).fixedSize(horizontal: false, vertical: true)
            }
            HStack {
                Spacer()
                Button("Cancel") { dismiss() }.keyboardShortcut(.cancelAction)
                Button("Save") { save() }.keyboardShortcut(.defaultAction)
            }
        }
        .padding(20)
        .frame(width: 460)
    }

    private func save() {
        guard let login = model.read() else { return }
        if printer.setSnmpLogin(login) { dismiss() } else { refused = true }
    }
}

enum SnmpAccessText {
    static let explanation = "Inkvolt Print reads this printer's status and supplies over SNMP, with the read community the printer's "
        + "administrator set. It's kept in your keychain, used only to read the printer, and never changes anything on it."
    static let keychainRefused = "The keychain didn't keep it, so it isn't used. Try again, or restart your Mac."
}
