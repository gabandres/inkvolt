import AppKit
import PrintCore
import PrintMac
import SwiftUI

/// The window of a phone scan (roadmap 4.6; Windows' Scan tab phone panel, `PhoneScanViewModel`): the QR code of the page's
/// address, the address itself, the certificate's fingerprint and the line about the phone (`PhoneScan.statusText`). Done
/// ends the session as the phone's Done does; closing the window does too. What is served and to whom is `PhoneSession`'s;
/// this only shows it.
@MainActor
enum PhoneWindow {
    private static var window: NSWindow?
    private static var closing: NSObjectProtocol?
    private(set) static var model: PhoneScanModel?

    @discardableResult
    static func show(_ link: PhoneLink, demo: Bool) -> PhoneScanModel {
        close()
        let model = PhoneScanModel(link: link)
        self.model = model
        let w = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 440, height: 560), styleMask: [.titled, .closable, .miniaturizable],
                         backing: .buffered, defer: false)
        w.contentView = NSHostingView(rootView: PhoneScanView(model: model))
        w.title = demo ? String(localized: "Scan with Your Phone — Demo") : String(localized: "Scan with Your Phone")
        w.isReleasedWhenClosed = false
        w.isRestorable = false
        w.center()
        window = w
        closing = NotificationCenter.default.addObserver(forName: NSWindow.willCloseNotification, object: w, queue: .main) { _ in
            MainActor.assumeIsolated { Self.closed() }
        }
        model.onDone = { Self.close() }
        NSApp.activate()
        w.makeKeyAndOrderFront(nil)
        return model
    }

    /// The open window's content size, for `--report`.
    static var size: NSSize? { window.flatMap { $0.isVisible ? $0.contentLayoutRect.size : nil } }

    static func close() { window?.close() }

    private static func closed() {
        if let closing { NotificationCenter.default.removeObserver(closing) }
        closing = nil
        window = nil
        model?.link.session.finish() // the scan ends, its pages kept
        model = nil
    }
}

/// The window's model: the code and the phone's state, followed from the session's changes.
@MainActor
@Observable
final class PhoneScanModel {
    let link: PhoneLink
    let qr: NSImage?
    private(set) var status: String
    private(set) var finished = false
    @ObservationIgnored var onDone: (() -> Void)?

    init(link: PhoneLink) {
        self.link = link
        qr = PhoneQrCode.image(link.url).map { NSImage(cgImage: $0, size: NSSize(width: $0.width, height: $0.height)) }
        status = PhoneScan.statusText(link.session.state, link.session.received)
        link.session.onChange { [weak self] in
            Task { @MainActor in self?.refresh() }
        }
    }

    private func refresh() {
        let was = status
        status = PhoneScan.statusText(link.session.state, link.session.received)
        finished = link.session.state == .finished
        if status != was { NSAccessibility.post(element: NSApp as Any, notification: .announcementRequested, userInfo: [.announcement: status]) }
    }

    /// The certificate's first eight bytes, as a browser's certificate view shows them.
    var fingerprint: String { String(localized: "Certificate \(link.shortFingerprint)") }

    func done() {
        link.session.finish()
        onDone?()
    }
}

struct PhoneScanView: View {
    let model: PhoneScanModel

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            Text("Point your phone's camera at the code, then open the link it shows. Your phone must be on the same Wi-Fi as this Mac.")
                .fixedSize(horizontal: false, vertical: true)
            HStack {
                Spacer()
                if let qr = model.qr {
                    Image(nsImage: qr).interpolation(.none).resizable().frame(width: 264, height: 264)
                        .padding(16).background(Color.white)
                        .accessibilityLabel(String(localized: "QR code of the scan's address"))
                }
                Spacer()
            }
            VStack(alignment: .leading, spacing: 4) {
                Text("Or open this address on the phone:").font(.callout).foregroundStyle(.secondary)
                Text(model.link.url).font(.callout.monospaced()).textSelection(.enabled).lineLimit(2)
                Text(model.fingerprint).font(.caption.monospaced()).foregroundStyle(.secondary)
                    .help(String(localized: "The phone's browser warns about this certificate the first time: this Mac made it for the scan. Its fingerprint begins like this."))
            }
            Text(model.status).fixedSize(horizontal: false, vertical: true)
                .accessibilityAddTraits(.updatesFrequently)
            HStack {
                Spacer()
                Button("Done") { model.done() }
                    .keyboardShortcut(.defaultAction)
            }
        }
        .padding(20)
        .frame(width: 440)
    }
}
