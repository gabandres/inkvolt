import AppKit
import AVFoundation
import PrintCore
import PrintMac
import SwiftUI

/// The camera window of a camera scan (roadmap 4.12; Windows' `CameraWindow`): the cameras macOS lists, the chosen one's
/// live picture, Capture page (the next frame in full, to `CameraSession`) and Done. Which format and when a capture counts
/// are PrintCore's (`CameraFormats`, `CameraSession`); this shows the picture and stops the camera when the window closes.
@MainActor
enum CameraWindow {
    private static var window: NSWindow?
    private static var closing: NSObjectProtocol?
    private(set) static var model: CameraScanModel?

    /// Opens the window for `session`; closing it (or Done) finishes the scan.
    @discardableResult
    static func show(_ session: CameraSession, cameras: any Cameras, demo: Bool) -> CameraScanModel {
        close()
        let model = CameraScanModel(cameras: cameras, session: session)
        self.model = model
        let w = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 760, height: 560), styleMask: [.titled, .closable, .resizable, .miniaturizable],
                         backing: .buffered, defer: false)
        w.contentView = NSHostingView(rootView: CameraScanView(model: model))
        w.title = demo ? String(localized: "Scan with a Camera — Demo") : String(localized: "Scan with a Camera")
        w.isReleasedWhenClosed = false
        w.isRestorable = false
        w.contentMinSize = NSSize(width: 520, height: 420)
        w.center()
        window = w
        closing = NotificationCenter.default.addObserver(forName: NSWindow.willCloseNotification, object: w, queue: .main) { _ in
            MainActor.assumeIsolated { Self.closed() }
        }
        model.onDone = { Self.close() }
        NSApp.activate()
        w.makeKeyAndOrderFront(nil)
        Task { await model.start() }
        return model
    }

    /// The open window's content size, for `--report`.
    static var size: NSSize? { window.flatMap { $0.isVisible ? $0.contentLayoutRect.size : nil } }

    static func close() { window?.close() }

    private static func closed() {
        if let closing { NotificationCenter.default.removeObserver(closing) }
        closing = nil
        window = nil
        let model = self.model
        self.model = nil
        Task { await model?.stop() }
    }
}

/// The window's model (Windows' `CameraScanViewModel`).
@MainActor
@Observable
final class CameraScanModel {
    private(set) var cameras: [CameraInfo] = []
    var camera: CameraInfo? {
        didSet { if oldValue != camera { Task { await open(camera) } } }
    }
    /// The line under the picture: what to do, how many pages, or why the camera didn't start.
    private(set) var status: String
    private(set) var isCapturing = false
    /// The live picture: AVFoundation's session, or demo mode's still frame.
    private(set) var preview: CameraPreview = .none
    @ObservationIgnored private(set) var feed: (any CameraFeed)?
    @ObservationIgnored private let source: any Cameras
    @ObservationIgnored let session: CameraSession
    @ObservationIgnored private var opening = 0
    @ObservationIgnored var onDone: (() -> Void)?

    enum CameraPreview {
        case none
        case live(AVCaptureSession)
        case still(NSImage)
    }

    init(cameras: any Cameras, session: CameraSession) {
        source = cameras
        self.session = session
        status = session.statusText()
    }

    var hasCameraChoice: Bool { cameras.count > 1 }
    var canCapture: Bool { feed != nil && !isCapturing && session.canCapture }

    /// Lists the cameras and starts the first; says so when there's none.
    func start() async {
        cameras = await source.list()
        guard let first = cameras.first else {
            status = loc("No camera found. Plug in a webcam or document camera, then try again.")
            return
        }
        camera = first
    }

    private func open(_ camera: CameraInfo?) async {
        opening += 1
        let turn = opening
        await stopFeed()
        guard let camera, !session.isFinished else { return }
        do {
            let feed = try await source.open(camera)
            guard turn == opening, !session.isFinished else {
                await feed.close() // another camera was chosen meanwhile, or the scan ended
                return
            }
            self.feed = feed
            if let live = feed as? AVCameraFeed {
                preview = .live(live.session)
            } else if let frame = await feed.capture(), let image = Self.image(frame.picture) {
                preview = .still(image)
            }
            status = session.statusText()
        } catch let e as CameraError {
            if turn == opening { status = e.message }
        } catch {
            if turn == opening { status = loc("The camera didn't start. Another app may be using it: close it, or choose another camera, and try again.") }
        }
    }

    /// The camera's next frame becomes the scan's next page (one capture at a time; Capture is off while the Mac catches up).
    func capture() async {
        guard canCapture else { return }
        isCapturing = true
        let taken = await session.capture(feed)
        isCapturing = false
        status = session.statusText()
        if taken { NSAccessibility.post(element: NSApp as Any, notification: .announcementRequested, userInfo: [.announcement: status]) }
        refreshSoon()
    }

    /// The status follows the pages being made (Capture comes back once the Mac has caught up).
    private func refreshSoon() {
        Task {
            for _ in 0..<40 where !session.canCapture && !session.isFinished {
                try? await Task.sleep(for: .milliseconds(250))
            }
            status = session.statusText()
        }
    }

    func done() {
        session.finish()
        onDone?()
    }

    /// The window closed: the scan ends (its pages kept) and the camera stops.
    func stop() async {
        session.finish()
        opening += 1
        await stopFeed()
    }

    private func stopFeed() async {
        guard let feed else { return }
        self.feed = nil
        preview = .none
        await feed.close()
    }

    static func image(_ p: PrintCore.Picture) -> NSImage? {
        guard let cg = ImageIOPhotoCodec.image(p) else { return nil }
        return NSImage(cgImage: cg, size: NSSize(width: p.width, height: p.height))
    }
}

struct CameraScanView: View {
    @Bindable var model: CameraScanModel

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            if model.hasCameraChoice {
                Picker("Camera", selection: $model.camera) {
                    ForEach(model.cameras, id: \.self) { Text($0.name).tag(Optional($0)) }
                }
                .frame(maxWidth: 360)
            }
            ZStack {
                Rectangle().fill(.black)
                switch model.preview {
                case .live(let session): CameraPreviewLayer(session: session)
                case .still(let image): Image(nsImage: image).resizable().scaledToFit()
                case .none: EmptyView()
                }
            }
            .accessibilityElement()
            .accessibilityLabel(String(localized: "What the camera sees"))
            Text(model.status).fixedSize(horizontal: false, vertical: true)
                .accessibilityAddTraits(.updatesFrequently)
            HStack {
                Spacer()
                Button("Done") { model.done() }
                Button("Capture Page") { Task { await model.capture() } }
                    .keyboardShortcut(.space, modifiers: [])
                    .buttonStyle(.borderedProminent)
                    .disabled(!model.canCapture)
                    .help(String(localized: "Takes the camera's picture as the next page (Space)"))
            }
        }
        .padding(16)
    }
}

/// AVFoundation's live picture of a session.
private struct CameraPreviewLayer: NSViewRepresentable {
    let session: AVCaptureSession

    func makeNSView(context: Context) -> NSView {
        let view = NSView()
        let layer = AVCaptureVideoPreviewLayer(session: session)
        layer.videoGravity = .resizeAspect
        view.layer = layer
        view.wantsLayer = true
        return view
    }

    func updateNSView(_ view: NSView, context: Context) {
        (view.layer as? AVCaptureVideoPreviewLayer)?.session = session
    }
}
