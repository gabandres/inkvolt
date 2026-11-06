import AppKit
import Observation
import PrintCore
import PrintMac
import SwiftUI

/// The key's copy in state.json (`PrintState.proKey`; the Windows app's `StateProStore`): behind the file both Inkvolt apps
/// share (`SharedProStore`), it holds a key only while that file can't be written.
final class StateProStore: ProStore {
    private let state: StateStore

    init(_ state: StateStore) { self.state = state }

    func read() -> String? {
        let key = state.read { $0.proKey } ?? ""
        return key.isEmpty ? nil : key
    }

    func write(_ key: String?) { state.change { $0.proKey = key?.isEmpty == false ? key : nil } }
}

/// Inkvolt Print's Pro check, set up at launch before anything asks it: CryptoKit's signature check, and the key in the
/// app group container Inkvolt PDF reads too (`ProKeyRoot`), with state.json behind it. Demo mode keeps a key in memory
/// only, as Windows' does.
@MainActor
enum ProSetup {
    static func configure(_ model: AppModel) {
        Pro.verifier = CryptoKitProVerifier()
        Pro.store = model.isDemo ? MemoryProStore() : ProKeyRoot.store(own: StateProStore(model.store))
        Usm.crypto = AppleSnmpCrypto() // SNMPv3's (roadmap 3.2), before any printer connects
    }

    /// One line for `--report`: the licence's state, and whether the shared file's folder is there (nothing written).
    static var reportLine: String {
        let state = Pro.licence.map { "licensed (\($0.products.joined(separator: ",")))" } ?? (Pro.problem != nil ? "key not accepted" : "none")
        let root = ProKeyRoot.url.map { url in
            let file = ProKeyFile.pathUnder(url.path)
            return "group container found, key file \(FileManager.default.fileExists(atPath: file) ? "present" : "absent")"
        } ?? "no group container"
        return "Inkvolt Pro: \(state); enforced \(Pro.enforced); \(root)"
    }
}

/// What Help › Inkvolt Pro… shows and does (the Windows app's `ProWindow`): Free or Pro (licensed to whom), a box to
/// paste a key with its refusal in plain words, Remove Licence. A Pro feature that isn't unlocked opens it with that
/// feature, whose description then heads the window. Unlike Windows' there is no Get Inkvolt Pro button, price or link
/// to the shop: this copy is the Mac App Store's, whose guidelines forbid sending a buyer to another way to pay outside
/// the United States (3.1.1(a); research file, "The Pro key's shared file"). A key bought elsewhere is entered here.
@MainActor @Observable
final class ProPanel {
    static let shared = ProPanel()

    var feature: ProFeature?
    var key = ""
    var error: String?
    /// Bumped by every change, so the window reads `Pro` again.
    private(set) var revision = 0

    /// Checks and keeps the key; a refusal shows under the box.
    @discardableResult
    func enter() -> Bool {
        do {
            try Pro.install(key)
            key = ""
            error = nil
            revision += 1
            return true
        } catch let e as ProKeyError {
            error = e.message
        } catch {
            self.error = "\(error)"
        }
        return false
    }

    func remove() {
        Pro.remove()
        error = nil
        revision += 1
    }
}

/// The window itself: one, brought forward when it is open already.
@MainActor
enum ProWindow {
    private static var window: NSWindow?

    static func show(feature: ProFeature? = nil) {
        let panel = ProPanel.shared
        panel.feature = feature
        panel.error = nil
        if window == nil {
            // The hosting view sizes the window to the view, then as it changes (a key entered, an error shown).
            let host = NSHostingView(rootView: ProView(panel: panel))
            let w = NSWindow(contentRect: NSRect(origin: .zero, size: host.fittingSize), styleMask: [.titled, .closable], backing: .buffered, defer: false)
            w.contentView = host
            w.title = "Inkvolt Pro"
            w.isReleasedWhenClosed = false
            w.isRestorable = false
            w.center()
            window = w
        }
        NSApp.activate()
        window?.makeKeyAndOrderFront(nil)
    }

    static func close() { window?.close() }

    /// The open window's content size, for `--report`.
    static var size: NSSize? { window.flatMap { $0.isVisible ? $0.contentLayoutRect.size : nil } }
}

struct ProView: View {
    @Bindable var panel: ProPanel
    @State private var confirmingRemove = false

    var body: some View {
        let _ = panel.revision // read Pro again after every change
        VStack(alignment: .leading, spacing: 0) {
            Text("Inkvolt Pro").font(.system(size: 20, weight: .semibold)).padding(.bottom, 12)
            if let feature = panel.feature, !Pro.allows(feature) { FeatureBanner(feature: feature).padding(.bottom, 14) }
            if let licence = Pro.licence { licensed(licence) } else { unlicensed }
            HStack {
                Spacer()
                Button("Close") { ProWindow.close() }.keyboardShortcut(.cancelAction).frame(minWidth: 96)
            }
            .padding(.top, 16)
        }
        .padding(EdgeInsets(top: 20, leading: 24, bottom: 16, trailing: 24))
        .frame(width: 560, alignment: .leading)
        .fixedSize(horizontal: false, vertical: true)
        .alert("Remove the Inkvolt Pro licence from this Mac?", isPresented: $confirmingRemove) {
            Button("Remove", role: .destructive) { panel.remove() }
            Button("Cancel", role: .cancel) {}
        } message: {
            Text("Files the Pro features made stay as they are, and you can enter the key again any time.")
        }
    }

    @ViewBuilder
    private func licensed(_ licence: ProLicence) -> some View {
        Text("Pro licensed to \(licence.name)").font(.system(size: 16, weight: .semibold))
        Caption(Self.keyFor(licence))
        if !Pro.enforced {
            Caption("Everything in Inkvolt Print is free while it launches; your licence will keep the Pro features (supply history export, batch print lists and the command line, fleet export, scanner sharing, SNMPv3) when they start asking for a key.")
        }
        Button("Remove Licence") { confirmingRemove = true }.padding(.top, 12)
    }

    @ViewBuilder
    private var unlicensed: some View {
        if Pro.enforced {
            Text("Free").font(.system(size: 16, weight: .semibold))
            Caption("Inkvolt Pro unlocks the office features (supply history export, batch print lists and the command line, fleet export, scanner sharing, SNMPv3), with one key for Inkvolt Print and Inkvolt PDF. The key is checked on this Mac, works offline, on Windows and on the Mac, and stays through reinstalling. Everything else in Inkvolt Print is free and stays free.")
        } else {
            Text("Everything is free while Inkvolt Print launches").font(.system(size: 16, weight: .semibold))
            Caption("That includes the Pro features to come: supply history export, batch print lists and the command line, fleet export, scanner sharing, SNMPv3. One Inkvolt Pro key serves Inkvolt Print and Inkvolt PDF, on Windows and on the Mac, and keeps the Pro features when they start asking for one.")
        }
        if let problem = Pro.problem {
            Text(problem).foregroundStyle(.red).fixedSize(horizontal: false, vertical: true).padding(.top, 8)
        }
        Text("Have a key? Paste it here").fontWeight(.semibold).padding(.top, 20).padding(.bottom, 4)
        TextEditor(text: $panel.key)
            .font(.system(.body, design: .monospaced))
            .autocorrectionDisabled()
            .frame(height: 64)
            .overlay(RoundedRectangle(cornerRadius: 4).stroke(Color(nsColor: .separatorColor)))
            .accessibilityLabel("Licence key")
        if let error = panel.error {
            Text(error).foregroundStyle(.red).fixedSize(horizontal: false, vertical: true).padding(.top, 6)
        }
        Button("Enter Key") { panel.enter() }.keyboardShortcut(.defaultAction).padding(.top, 8)
    }

    /// Windows' Pro_KeyFor and Pro_KeyForWithPdf, on this Mac.
    static func keyFor(_ licence: ProLicence) -> String {
        let issued = licence.issuedDate?.formatted(date: .long, time: .omitted) ?? licence.issued
        let pdf = licence.covers(ProKeys.productPdf) ? "; Inkvolt PDF on this Mac finds it too" : ""
        return "Key for \(licence.email), issued \(issued). It is checked on this Mac, works offline, on Windows and on the Mac, and stays through reinstalling\(pdf). Thank you for supporting Inkvolt Print."
    }
}

/// A locked feature's name and what it does, at the top of the window.
private struct FeatureBanner: View {
    let feature: ProFeature

    var body: some View {
        VStack(alignment: .leading, spacing: 4) {
            Text(Pro.locked(feature)).fontWeight(.semibold)
            Text("\(Pro.title(feature)): \(Pro.describe(feature))")
        }
        .fixedSize(horizontal: false, vertical: true)
        .padding(EdgeInsets(top: 10, leading: 14, bottom: 10, trailing: 14))
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(Color.accentColor.opacity(0.12), in: RoundedRectangle(cornerRadius: 6))
    }
}

private struct Caption: View {
    let text: String

    init(_ text: String) { self.text = text }

    var body: some View {
        Text(text).font(.callout).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true).padding(.top, 4)
    }
}
