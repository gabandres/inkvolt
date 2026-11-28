import PrintCore
import PrintMac
import SwiftUI

/// Copy on the Printer… (roadmap 3.3; the Windows Copy tab's "Copy with: The printer itself"): the printer copies by itself
/// with the settings on its own control panel, started by one PUT over HTTPS, sent once (`PrinterCopier`). No macOS queue,
/// no scan through this Mac. A refusal or no answer is said in words, never sent again on its own; the admin password, when
/// the printer asks for it, is asked here and kept in the Keychain as the Settings tab's.
@MainActor @Observable
final class PrinterCopyModel {
    enum Step: Equatable {
        case ready
        case starting
        case copying
        case failed(String)
        case needsPassword(wrong: Bool)
    }

    private(set) var step = Step.ready
    @ObservationIgnored private let printer: PrinterModel

    init(printer: PrinterModel) { self.printer = printer }

    /// Asks the printer to copy, once.
    func copy() async {
        guard let copier = printer.printerCopier else {
            step = .failed(loc("The printer doesn't take copy requests from apps after all. Copy from its control panel instead."))
            return
        }
        step = .starting
        do {
            let result = try await copier.copy()
            step = result.problem.map { .failed($0) } ?? .copying
        } catch let auth as LedmAuthRequiredError {
            step = .needsPassword(wrong: auth.credentialsWereSent)
        } catch {
            step = .failed(String(localized: "Something went wrong while asking the printer to copy, and it may already be copying. Check its control panel before copying again."))
        }
    }

    /// The password asked for: set on the connection (sent over HTTPS only), kept in the Keychain, and the copy asked again.
    func usePassword(_ password: String) async {
        guard let conn = await printer.connection() else { return }
        conn.http.setCredentials(user: "admin", password: password)
        PrinterPasswords.set(password, for: printer.id)
        await copy()
    }
}

struct PrinterCopySheet: View {
    let printer: PrinterModel
    @State private var model: PrinterCopyModel
    @Environment(\.dismiss) private var dismiss

    init(printer: PrinterModel) {
        self.printer = printer
        _model = State(initialValue: PrinterCopyModel(printer: printer))
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text("Copy on the Printer").font(.title2.weight(.semibold))
            Text("Put the pages face up in the printer's document feeder, or one page face down on its glass, then press Copy. The printer copies by itself.")
                .fixedSize(horizontal: false, vertical: true)
            Text("The printer copies with the copies, two-sided and other settings on its own control panel.")
                .foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
            PrinterCopyStatus(model: model, printer: printer)
            HStack {
                Spacer()
                Button("Close", role: .cancel) { dismiss() }.keyboardShortcut(.cancelAction)
                Button("Copy") { Task { await model.copy() } }
                    .keyboardShortcut(.defaultAction)
                    .disabled(!model.canCopy)
            }
        }
        .padding(20)
        .frame(width: 460)
    }
}

extension PrinterCopyModel {
    /// Not asking yet, and not waiting for the password.
    var canCopy: Bool {
        if case .needsPassword = step { return false }
        return step != .starting
    }
}

/// Where the printer's own copy got to, and the admin password when the printer asks for it (Copy on the Printer… and Copy…'s
/// The printer itself).
struct PrinterCopyStatus: View {
    let model: PrinterCopyModel
    let printer: PrinterModel
    @State private var password = ""

    var body: some View { stepView }

    @ViewBuilder private var stepView: some View {
        switch model.step {
        case .ready:
            EmptyView()
        case .starting:
            Label(String(localized: "Asking the printer to copy…"), systemImage: "hourglass")
        case .copying:
            Label(String(localized: "The printer is copying, with the settings on its control panel."), systemImage: "checkmark.circle")
        case .failed(let problem):
            Label(problem, systemImage: "exclamationmark.triangle").foregroundStyle(.red).fixedSize(horizontal: false, vertical: true)
        case .needsPassword(let wrong):
            VStack(alignment: .leading, spacing: 8) {
                Text(wrong ? String(localized: "That password didn't work") : String(localized: "\(printer.name) asks for its admin password")).font(.headline)
                Text("It's the password of the printer's web page (often on a label on the printer, or set when it was installed). Inkvolt Print keeps it in your keychain and sends it only to this printer, over HTTPS.")
                    .foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
                HStack {
                    SecureField("Password", text: $password)
                    Button("Send") {
                        let p = password
                        password = ""
                        Task { await model.usePassword(p) }
                    }
                    .disabled(password.isEmpty)
                }
            }
        }
    }
}
