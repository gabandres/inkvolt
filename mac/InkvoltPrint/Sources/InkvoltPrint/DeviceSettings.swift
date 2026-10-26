import AppKit
import Observation
import PrintCore
import PrintMac
import SwiftUI

/// A printer's Settings tab (the Windows app's `SettingsViewModel`): the LEDM settings HP printers let apps change, and
/// automatic firmware updates. Changes go to the printer over HTTPS with its admin password when it asks for one; the
/// password is kept in the Keychain (`PrinterPasswords`), never in the state file.
@MainActor @Observable
final class DeviceSettingsModel {
    private(set) var settings: LedmSettings?
    private(set) var firmware: FirmwareUpdateSettings?
    /// Values changed here, not saved yet: key → value.
    var edits: [String: String] = [:]
    private(set) var loading = false
    private(set) var saving = false
    private(set) var message: String?
    private(set) var problem: String?
    /// The printer wants its admin password: the sheet asks.
    var askingPassword = false
    private(set) var passwordWasWrong = false

    @ObservationIgnored private let printer: PrinterModel
    @ObservationIgnored private var pending: (() async -> Void)?

    init(printer: PrinterModel) { self.printer = printer }

    var hasSettings: Bool { !(settings?.items.isEmpty ?? true) || firmware != nil }
    var hasChanges: Bool { edits.contains { key, value in settings?.items.first { $0.def.key == key }?.value != value } }

    func load() async {
        loading = true
        defer { loading = false }
        problem = nil
        guard let conn = await printer.connection(), let ledm = conn.ledm else {
            problem = "Settings can be changed while the printer is connected (HP printers with LEDM)."
            return
        }
        do {
            settings = try await ledm.settings()
            firmware = try? await ledm.firmwareUpdate()
            edits = [:]
        } catch {
            problem = "The printer didn't send its settings. Try again in a moment."
        }
    }

    func value(_ s: LedmSetting) -> String { edits[s.def.key] ?? s.value }

    func set(_ s: LedmSetting, _ value: String) { edits[s.def.key] = value == s.value ? nil : value }

    func save() async {
        guard let settings else { return }
        let changes = settings.items.compactMap { s in edits[s.def.key].map { (def: s.def, value: $0) } }.filter { c in
            settings.items.first { $0.def.key == c.def.key }?.value != c.value
        }
        guard !changes.isEmpty else { return }
        await write("Saved.") { ledm in try await ledm.save(changes, over: settings) }
    }

    func setFirmware(_ mode: FirmwareUpdateMode) async {
        guard let current = firmware, mode != current.mode else { return }
        await write(nil) { ledm in
            try await ledm.setFirmwareUpdate(mode, in: current)
            if let back = try await ledm.firmwareUpdate() {
                switch FirmwareUpdateSettings.judge(mode, back.mode) {
                case .kept: self.message = "Saved."
                case .notifyInstalls: self.message = "This printer installs updates whenever it checks for them, so it's set to update automatically."
                case .other: self.message = "The printer kept its own setting."
                }
            }
        }
    }

    /// Sends a change with the saved password (when there is one); asks for it when the printer wants one, then sends again.
    private func write(_ done: String?, _ body: @escaping (LedmClient) async throws -> Void) async {
        guard let conn = await printer.connection(), let ledm = conn.ledm else {
            problem = "The printer isn't connected."
            return
        }
        saving = true
        problem = nil
        message = nil
        defer { saving = false }
        if let password = PrinterPasswords.password(for: printer.id) { conn.http.setCredentials(user: "admin", password: password) }
        do {
            try await body(ledm)
            if let done { message = done }
            await load()
        } catch let e as LedmAuthRequiredError {
            passwordWasWrong = e.credentialsWereSent
            pending = { await self.write(done, body) }
            askingPassword = true
        } catch {
            problem = "The printer didn't take the change. Check it's still connected, then try again."
        }
    }

    /// The password the sheet asked for: kept in the Keychain once the printer takes it.
    func usePassword(_ password: String) async {
        guard let conn = await printer.connection() else { return }
        conn.http.setCredentials(user: "admin", password: password)
        PrinterPasswords.set(password, for: printer.id)
        let retry = pending
        pending = nil
        await retry?()
    }

    func forgetPassword() {
        PrinterPasswords.remove(for: printer.id)
        message = "The saved password was removed."
    }
}

struct DeviceSettingsView: View {
    let printer: PrinterModel
    @State private var model: DeviceSettingsModel
    @State private var password = ""

    init(printer: PrinterModel) {
        self.printer = printer
        _model = State(initialValue: DeviceSettingsModel(printer: printer))
    }

    var body: some View {
        Form {
            if let problem = model.problem { Text(problem).foregroundStyle(.red) }
            if let settings = model.settings {
                let groups = Dictionary(grouping: settings.items, by: \.def.group)
                ForEach(groups.keys.sorted(), id: \.self) { group in
                    Section(group) {
                        ForEach(groups[group] ?? [], id: \.def.key) { s in SettingRow(setting: s, model: model) }
                    }
                }
            }
            if let fw = model.firmware {
                Section("Firmware") {
                    if let status = fw.statusMessage { Text(status).foregroundStyle(.secondary) }
                    Picker("Updates", selection: Binding(get: { fw.mode }, set: { mode in Task { await model.setFirmware(mode) } })) {
                        ForEach(fw.choices, id: \.self) { Text(Self.label($0)).tag($0) }
                    }
                    .disabled(!fw.canChange || model.saving)
                }
            }
            Section {
                HStack {
                    if let message = model.message { Text(message).foregroundStyle(.secondary) }
                    Spacer()
                    if model.saving || model.loading { ProgressView().controlSize(.small) }
                    if PrinterPasswords.password(for: printer.id) != nil {
                        Button("Forget Password") { model.forgetPassword() }
                    }
                    Button("Revert") { model.edits = [:] }.disabled(!model.hasChanges)
                    Button("Save") { Task { await model.save() } }.buttonStyle(.borderedProminent).disabled(!model.hasChanges || model.saving)
                }
            }
        }
        .formStyle(.grouped)
        .task { await model.load() }
        .sheet(isPresented: $model.askingPassword) {
            VStack(alignment: .leading, spacing: 12) {
                Text(model.passwordWasWrong ? "That password didn't work" : "\(printer.name) asks for its admin password").font(.headline)
                Text("It's the password of the printer's web page (often on a label on the printer, or set when it was installed). Inkvolt Print keeps it in your keychain and sends it only to this printer, over HTTPS.")
                    .foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
                SecureField("Password", text: $password)
                HStack {
                    Spacer()
                    Button("Cancel", role: .cancel) { model.askingPassword = false }.keyboardShortcut(.cancelAction)
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

    static func label(_ mode: FirmwareUpdateMode) -> String {
        switch mode {
        case .off: "Don't check"
        case .notify: "Tell me when there's an update"
        case .automatic: "Install updates automatically"
        }
    }
}

private struct SettingRow: View {
    let setting: LedmSetting
    let model: DeviceSettingsModel

    var body: some View {
        switch setting.def.kind {
        case .choice:
            Picker(setting.def.label, selection: Binding(get: { model.value(setting) }, set: { model.set(setting, $0) })) {
                ForEach(setting.choices, id: \.self) { Text(setting.display($0)).tag($0) }
            }
        case .text:
            TextField(setting.def.label, text: Binding(get: { model.value(setting) }, set: { v in
                model.set(setting, setting.maxLength.map { String(v.prefix($0)) } ?? v)
            }))
        case .integer:
            Stepper(value: Binding(get: { Int(model.value(setting)) ?? setting.min ?? 0 }, set: { model.set(setting, String($0)) }),
                    in: (setting.min ?? 0)...(setting.max ?? 9999)) {
                Text("\(setting.def.label): \(model.value(setting))")
            }
        }
    }
}
