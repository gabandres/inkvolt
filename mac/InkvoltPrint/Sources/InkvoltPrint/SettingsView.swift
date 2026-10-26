import Observation
import PrintCore
import ServiceManagement
import SwiftUI

/// Inkvolt Print › Settings (⌘,): the menu bar item, opening at login, and the alerts (the Windows app's alert settings).
struct SettingsView: View {
    var body: some View {
        TabView {
            GeneralSettings().tabItem { Label("General", systemImage: "gearshape") }
            AlertsSettings().tabItem { Label("Alerts", systemImage: "bell") }
        }
        .frame(width: 520)
        .fixedSize(horizontal: false, vertical: true)
    }
}

private struct GeneralSettings: View {
    @Environment(AppModel.self) private var model
    @State private var login = LoginItem()

    var body: some View {
        Form {
            Section {
                Toggle("Keep Inkvolt Print in the menu bar", isOn: Binding(get: { model.settings.menuBar },
                                                                          set: { on in model.changeSettings { $0.menuBar = on } }))
                Text("Its icon shows how your printers are doing. Closing the window leaves Inkvolt Print running there: it reads each printer every 5 minutes (every 15 on battery or in Low Data Mode, less often when one doesn't answer). Quit from its menu. Off: Inkvolt Print quits when its window closes.")
                    .font(.callout).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
            }
            Section {
                Toggle("Open at login", isOn: Binding(get: { login.isOn }, set: { login.set($0) }))
                    .disabled(!model.settings.menuBar)
                if let note = login.note {
                    Text(note).font(.callout).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
                    if login.needsApproval {
                        Button("Open Login Items Settings") { SMAppService.openSystemSettingsLoginItems() }
                    }
                }
            }
        }
        .formStyle(.grouped)
        .onAppear { login.refresh() }
    }
}

/// Opening at login (`SMAppService.mainApp`): only when the user turns it on.
@MainActor @Observable
final class LoginItem {
    private(set) var status = SMAppService.mainApp.status
    private(set) var error: String?

    var isOn: Bool { status == .enabled || status == .requiresApproval }
    var needsApproval: Bool { status == .requiresApproval }

    var note: String? {
        if let error { return error }
        return needsApproval ? "macOS asks you to allow it: turn on Inkvolt Print in System Settings › General › Login Items." : nil
    }

    func refresh() { status = SMAppService.mainApp.status }

    func set(_ on: Bool) {
        error = nil
        do {
            if on { try SMAppService.mainApp.register() } else { try SMAppService.mainApp.unregister() }
        } catch {
            self.error = on ? "macOS didn't add Inkvolt Print to your login items." : "macOS didn't remove Inkvolt Print from your login items."
        }
        refresh()
    }
}

private struct AlertsSettings: View {
    @Environment(AppModel.self) private var model

    var body: some View {
        let s = model.settings
        Form {
            Section {
                Toggle("Tell me about low supplies and printer problems", isOn: bind(\.alerts))
                Text("Once per problem, as a notification: a supply low or empty, a waste box almost full or full, a paper jam, no paper, an open cover or another printer error lasting a minute. Click it to see the printer. No ads, no shop links.")
                    .font(.callout).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
                Picker("Low supply at", selection: bind(\.lowPercent)) {
                    ForEach(AlertSettings.lowChoices, id: \.self) { Text("\($0)% or less").tag($0) }
                }
                .disabled(!s.alerts)
                Toggle("Tell me when a printer stops answering for 15 minutes", isOn: bind(\.offlineAlerts)).disabled(!s.alerts)
            }
            Section {
                Toggle("Quiet hours", isOn: bind(\.quietHours)).disabled(!s.alerts)
                HStack {
                    Picker("From", selection: bind(\.quietFrom)) { hours }
                    Picker("to", selection: bind(\.quietTo)) { hours }
                }
                .disabled(!s.alerts || !s.quietHours)
                Text("Alerts that come up meanwhile wait until quiet hours end, if the problem is still there.")
                    .font(.callout).foregroundStyle(.secondary)
            }
            if let text = s.pauseText(now: Date()) {
                Section {
                    HStack {
                        Text(text)
                        Spacer()
                        Button("Resume Alerts") { model.resumeAlerts() }
                    }
                }
            }
        }
        .formStyle(.grouped)
        .disabled(!s.menuBar)
    }

    private var hours: some View {
        ForEach(0..<24, id: \.self) { h in
            Text(Calendar.current.date(bySettingHour: h, minute: 0, second: 0, of: Date())!.formatted(date: .omitted, time: .shortened)).tag(h)
        }
    }

    private func bind<T>(_ key: WritableKeyPath<AlertSettings, T>) -> Binding<T> {
        Binding(get: { model.settings[keyPath: key] }, set: { value in model.changeSettings { $0[keyPath: key] = value } })
    }
}
