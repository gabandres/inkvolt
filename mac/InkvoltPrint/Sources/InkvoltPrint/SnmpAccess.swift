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
    var proNote: String? { Pro.allows(.snmpV3) ? nil : String(localized: "\(Pro.locked(.snmpV3)) Help › Inkvolt Pro… enters a key.") }

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

    /// Nothing typed for the kind chosen (shown or not): the printer is asked with public.
    var isBlank: Bool {
        kind == .community ? community.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
            : userName.isEmpty && authPassphrase.isEmpty && privPassphrase.isEmpty
    }
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
            caption(String(localized: "Leave it blank for public, the community most printers ship with."))
        }
    }

    private var v3Fields: some View {
        VStack(alignment: .leading, spacing: 6) {
            TextField("User name", text: $model.userName).textFieldStyle(.roundedBorder)
            SecureField("Authentication passphrase (SHA-256)", text: $model.authPassphrase).textFieldStyle(.roundedBorder)
            SecureField("Privacy passphrase (AES-128)", text: $model.privPassphrase).textFieldStyle(.roundedBorder)
            caption(String(localized: "The printer's SNMPv3 user with authentication and privacy (authPriv). Every request is signed and encrypted, and only reads."))
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

/// The printer's menu › SNMP Access…: for a printer read over SNMP, the login it's read with. Save asks the printer with it
/// first (`SnmpLoginCheck`): kept, and connected again with, once the printer answers; a refusal says which part was
/// refused and nothing is kept; no answer (it may be off, or ignore a wrong community) lets Save Anyway keep it.
struct SnmpAccessSheet: View {
    let printer: PrinterModel
    @State private var model: SnmpAccessModel
    @State private var problem: String?
    @State private var checking = false
    /// The login that got no answer: Save keeps it as it is (Save Anyway).
    @State private var unanswered: SnmpLogin?
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
            if let problem {
                Text(problem).font(.callout).foregroundStyle(.red).fixedSize(horizontal: false, vertical: true)
            }
            HStack {
                if checking { ProgressView().controlSize(.small) }
                Spacer()
                Button("Cancel") { dismiss() }.keyboardShortcut(.cancelAction)
                Button(unanswered == nil ? String(localized: "Save") : String(localized: "Save Anyway")) { save() }.keyboardShortcut(.defaultAction).disabled(checking)
            }
        }
        .padding(20)
        .frame(width: 460)
    }

    private func save() {
        guard let login = model.read() else { return }
        if login == unanswered || login == printer.snmpLogin {
            keep(login)
            return
        }
        problem = nil
        unanswered = nil
        checking = true
        Task {
            let check = await printer.checkSnmpLogin(login)
            checking = false
            guard model.read() == login else { return } // edited while it was asked: Save asks again
            switch check {
            case .answered: keep(login)
            case .refused(let why): problem = SnmpAccessText.refusedHint(why)
            case .anotherDevice: problem = SnmpAccessText.anotherDevice
            case .noAnswer:
                problem = SnmpAccessText.unansweredHint(login)
                unanswered = login
            }
        }
    }

    private func keep(_ login: SnmpLogin) {
        if printer.setSnmpLogin(login) { dismiss() } else { problem = SnmpAccessText.keychainRefused }
    }
}

enum SnmpAccessText {
    static let explanation = String(localized: "Inkvolt Print reads this printer's status and supplies over SNMP, with the read community or SNMPv3 user the printer's administrator set. It's kept in your keychain, used only to read the printer, and never changes anything on it.")
    static let keychainRefused = String(localized: "The keychain didn't keep it, so it isn't used. Try again, or restart your Mac.")
    static let notAdded = String(localized: "The keychain didn't keep its SNMP access, so the printer wasn't added. Try again, or restart your Mac.")
    static let anotherDevice = String(localized: "Another device answers at this printer's address with it, so it wasn't kept.")

    /// The printer refused the login: which part, and that nothing was kept.
    static func refusedHint(_ why: SnmpRefusal) -> String { String(localized: "\(SnmpAccessError(why).description) Nothing was changed.") }

    /// Nothing answered with the login: what may be wrong, and that Save Anyway keeps it.
    static func unansweredHint(_ login: SnmpLogin) -> String {
        let what = login.user != nil ? String(localized: "The printer didn't answer over SNMPv3: check that it's on and that SNMPv3 is turned on in it.")
            : String(localized: "The printer didn't answer with this community: check it, and that the printer is on.")
        return String(localized: "\(what) Save Anyway keeps it as it is.")
    }

    /// What may be wrong when nothing answered at an address, about SNMP: the agent's refusal when it said why.
    static func noAnswerHint(_ login: SnmpLogin, refused: SnmpRefusal?) -> String {
        if let refused { return String(localized: "\(SnmpAccessError(refused).description) Check SNMP access below.") }
        if login.isDefault { return String(localized: "A printer that answers only SNMP may need its community or SNMPv3 user: open SNMP access below.") }
        return login.user != nil ? String(localized: "Check the SNMPv3 user name and passphrases too.") : String(localized: "Check the SNMP community too.")
    }
}
