import PrintCore
import SwiftUI

/// The Scan tab's "Scan from the printer's button" section (roadmap 2.2; the Windows app's `ScanButtonViewModel` card): what
/// the printer's `ScanButton` says, its switch and the preset a press runs. What it decides lives in PrintCore; this only
/// shows it. Hidden until a connection or scanner has been looked at; then it shows, also to say there's no way. When the
/// printer wants its admin password to add this Mac, it's asked for here (the Windows app sends the person to Printer
/// settings, which the Mac's Settings tab asks only when a setting is saved).
struct ScanButtonSection: View {
    let printer: PrinterModel
    @Environment(AppModel.self) private var app
    @State private var askingPassword = false
    @State private var password = ""

    var body: some View {
        _ = printer.buttonRevision
        let button: ScanButton = printer.scanButton
        let way: ScanButtonWay = button.way
        return Group {
            if way != .unknown {
                Section("Scan from the printer's button") {
                    Text(button.text(printer.buttonPreset?.name)).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
                    if way == .panel || way == .driver { controls(button) }
                    if way == .panel && button.on && button.panelState == .needsPassword {
                        Button("Enter the Admin Password…") { askingPassword = true }
                    }
                }
            }
        }
        .sheet(isPresented: $askingPassword) { passwordSheet }
    }

    /// The switch and the preset (on their own: Xcode's type checker is slow on long view expressions).
    private func controls(_ button: ScanButton) -> some View {
        let on = Binding<Bool>(get: { button.on }, set: { value in Task { await button.setOn(value) } })
        let preset = Binding<String>(get: { printer.buttonPreset?.id ?? "" }, set: { id in button.setPreset(id) })
        let presets: [ScanPreset] = app.presets
        return Group {
            Toggle(button.switchText, isOn: on).help(button.text(printer.buttonPreset?.name))
            Picker("Runs", selection: preset) {
                ForEach(presets, id: \.id) { (p: ScanPreset) in Text(p.name).tag(p.id) }
            }
            .accessibilityLabel(Text("The scan preset a press of the printer's button runs"))
        }
    }

    private var passwordSheet: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text(String(localized: "\(printer.name) asks for its admin password")).font(.headline)
            Text("It's the password of the printer's web page (often on a label on the printer, or set when it was installed). Inkvolt Print keeps it in your keychain and sends it only to this printer, over HTTPS.")
                .foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
            SecureField("Password", text: $password)
            HStack {
                Spacer()
                Button("Cancel", role: .cancel) { askingPassword = false }.keyboardShortcut(.cancelAction)
                Button("Send") {
                    let p = password
                    password = ""
                    askingPassword = false
                    Task { await printer.useButtonPassword(p) }
                }
                .keyboardShortcut(.defaultAction)
                .disabled(password.isEmpty)
            }
        }
        .padding(20)
        .frame(width: 420)
    }
}
