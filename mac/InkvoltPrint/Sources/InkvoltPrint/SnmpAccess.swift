import Observation
import PrintCore
import SwiftUI

/// What the SNMP access fields hold (Add a Printer's and the printer's menu's; roadmap 3.2): the community a printer that
/// answers only SNMP is read with (blank: public), or an SNMPv3 user and its two passphrases, which is an Inkvolt Pro
/// feature (`Pro.allows`). The Windows app's `SnmpAccessFields`. Kept in the Keychain with the printer, never in the state
/// file.
@MainActor @Observable
final class SnmpAccessModel {
    enum Kind: Hashable { case community, v3 }

    var kind = Kind.community
    var community = ""
    var userName = ""
    var authPassphrase = ""
    var privPassphrase = ""
    /// Why what was entered can't be used; nil when it can (or nothing was asked yet).
    private(set) var error: String?

    init(_ current: SnmpLogin = .public) {
        if let user = current.user {
            kind = .v3
            userName = user.name
            authPassphrase = user.authPassphrase
            privPassphrase = user.privPassphrase
        } else {
            community = current.isDefault ? "" : current.community
        }
    }

    /// SNMPv3 waits for Inkvolt Pro: the fields say so.
    var proNote: String? { Pro.allows(.snmpV3) ? nil : "\(Pro.locked(.snmpV3)) Help › Inkvolt Pro… enters a key." }

    /// The login entered, or nil with the reason in `error` (and, for SNMPv3 without Inkvolt Pro, its window opened).
    func read() -> SnmpLogin? {
        do {
            let login = kind == .v3 ? try SnmpLogin.forUser(userName, authPassphrase, privPassphrase) : try SnmpLogin.forCommunity(community)
            if login.user != nil && !Pro.allows(.snmpV3) {
                error = Pro.locked(.snmpV3)
                ProWindow.show(feature: .snmpV3)
                return nil
            }
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
        VStack(alignment: .leading, spacing: 8) {
            Picker("Sign in with", selection: $model.kind) {
                Text("Community").tag(SnmpAccessModel.Kind.community)
                Text("SNMPv3 user").tag(SnmpAccessModel.Kind.v3)
            }
            .pickerStyle(.segmented)
            .onChange(of: model.kind) { model.edited() }
            if model.kind == .community { communityFields } else { v3Fields }
            if let error = model.error {
                Text(error).font(.callout).foregroundStyle(.red).fixedSize(horizontal: false, vertical: true)
            }
        }
    }

    private var communityFields: some View {
        VStack(alignment: .leading, spacing: 6) {
            TextField("Community", text: $model.community, prompt: Text("public"))
                .textFieldStyle(.roundedBorder)
                .onChange(of: model.community) { model.edited() }
            caption("Leave it blank for public, the community most printers ship with.")
        }
    }

    private var v3Fields: some View {
        VStack(alignment: .leading, spacing: 6) {
            TextField("User name", text: $model.userName).textFieldStyle(.roundedBorder)
            SecureField("Authentication passphrase (SHA-256)", text: $model.authPassphrase).textFieldStyle(.roundedBorder)
            SecureField("Privacy passphrase (AES-128)", text: $model.privPassphrase).textFieldStyle(.roundedBorder)
            caption("The printer's SNMPv3 user with authentication and privacy (authPriv). Every request is signed and encrypted, and only reads.")
            if let note = model.proNote { caption(note) }
        }
        .onChange(of: model.userName) { model.edited() }
        .onChange(of: model.authPassphrase) { model.edited() }
        .onChange(of: model.privPassphrase) { model.edited() }
    }

    private func caption(_ text: String) -> some View {
        Text(text).font(.caption).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
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
    static let explanation = "Inkvolt Print reads this printer's status and supplies over SNMP, with the read community or SNMPv3 user "
        + "the printer's administrator set. It's kept in your keychain, used only to read the printer, and never changes anything on it."
    static let keychainRefused = "The keychain didn't keep it, so it isn't used. Try again, or restart your Mac."

    /// What may be wrong when nothing answered at an address, about SNMP: the agent's refusal when it said why.
    static func noAnswerHint(_ login: SnmpLogin, refused: SnmpRefusal?) -> String {
        if let refused { return "\(SnmpAccessError(refused)) Check SNMP access below." }
        if login.isDefault { return "A printer that answers only SNMP may need its community or SNMPv3 user: open SNMP access below." }
        return login.user != nil ? "Check the SNMPv3 user name and passphrases too." : "Check the SNMP community too."
    }
}
