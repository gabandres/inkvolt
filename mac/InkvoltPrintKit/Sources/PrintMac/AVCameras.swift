@preconcurrency import AVFoundation
import CoreMedia
import CoreVideo
import Foundation
import PrintCore

/// This Mac's cameras through AVFoundation (roadmap 4.12; Windows' `Windows.Media.Capture` cameras): the built-in FaceTime
/// camera, USB webcams and document cameras, an iPhone as Continuity Camera and its Desk View. Needs
/// `com.apple.security.device.camera` in the sandbox and `NSCameraUsageDescription`; macOS asks the user once (research
/// file, 4.12). A camera is opened at the format `CameraFormats.choose` picks, its frames as 32BGRA.
public struct AVCameras: Cameras {
    public init() {}

    public func list() async -> [CameraInfo] {
        let types: [AVCaptureDevice.DeviceType] = [.builtInWideAngleCamera, .external, .continuityCamera, .deskViewCamera]
        let found = AVCaptureDevice.DiscoverySession(deviceTypes: types, mediaType: .video, position: .unspecified).devices
        return found.map { CameraInfo(id: $0.uniqueID, name: $0.localizedName.isEmpty ? loc("Camera") : AlertText.clean($0.localizedName, 80)) }
    }

    public func open(_ camera: CameraInfo) async throws -> any CameraFeed {
        switch AVCaptureDevice.authorizationStatus(for: .video) {
        case .authorized: break
        case .notDetermined:
            guard await AVCaptureDevice.requestAccess(for: .video) else { throw CameraError(Self.denied) }
        default: throw CameraError(Self.denied)
        }
        guard let device = AVCaptureDevice(uniqueID: camera.id) else { throw CameraError(loc("No camera found. Plug in a webcam or document camera, then try again.")) }
        return try await AVCameraFeed.start(device)
    }

    static var denied: String {
        loc("macOS doesn't let Inkvolt Print use the camera. Turn it on in System Settings › Privacy & Security › Camera, then try again.")
    }

    /// A device's formats as `CameraFormats` reads them.
    static func formats(_ device: AVCaptureDevice) -> [(format: AVCaptureDevice.Format, described: CameraFormat)] {
        device.formats.map { f in
            let size = CMVideoFormatDescriptionGetDimensions(f.formatDescription)
            let fps = f.videoSupportedFrameRateRanges.map(\.maxFrameRate).max() ?? 0
            let code = CMFormatDescriptionGetMediaSubType(f.formatDescription)
            let subtype = String(bytes: [24, 16, 8, 0].map { UInt8(code >> $0 & 0xFF) }, encoding: .ascii) ?? "?"
            return (f, CameraFormat(Int(size.width), Int(size.height), fps, subtype))
        }
    }
}

/// One camera streaming into an `AVCaptureSession` (its live picture is the app's `AVCaptureVideoPreviewLayer` on `session`).
/// Frames are counted as they come and copied only when a capture asks for one: the next frame in full, as RGB.
public final class AVCameraFeed: NSObject, CameraFeed, AVCaptureVideoDataOutputSampleBufferDelegate, @unchecked Sendable {
    /// For the app's preview layer.
    public let session = AVCaptureSession()
    private let queue = DispatchQueue(label: "Inkvolt Print camera")
    private let lock = NSLock()
    private var frames: Int64 = 0
    private var frameSize = (width: 0, height: 0)
    private var waiting: [(id: Int, continuation: CheckedContinuation<CameraFrame?, Never>)] = []
    private var nextId = 0
    private var closed = false

    /// A capture that gets no frame in this long gives up (a camera that stopped sending).
    static let frameWait: TimeInterval = 5

    public var size: (width: Int, height: Int) { lock.withLock { frameSize } }

    static func start(_ device: AVCaptureDevice) async throws -> AVCameraFeed {
        guard let chosen = CameraFormats.choose(AVCameras.formats(device).map(\.described)),
              let format = AVCameras.formats(device).first(where: { $0.described == chosen })?.format else {
            throw CameraError(loc("This camera sends no picture Inkvolt Print can use. Choose another camera."))
        }
        let feed = AVCameraFeed()
        let handed = Chosen(device: device, format: format)
        try await withCheckedThrowingContinuation { (c: CheckedContinuation<Void, any Error>) in
            feed.queue.async {
                do {
                    try feed.configure(handed.device, handed.format)
                    feed.session.startRunning() // blocks until running, on the feed's own queue
                    c.resume()
                } catch {
                    c.resume(throwing: error)
                }
            }
        }
        return feed
    }

    /// The device and its format, handed to the feed's own queue (AVFoundation's objects aren't Sendable; only that queue
    /// touches them from then on).
    private struct Chosen: @unchecked Sendable {
        let device: AVCaptureDevice
        let format: AVCaptureDevice.Format
    }

    private func configure(_ device: AVCaptureDevice, _ format: AVCaptureDevice.Format) throws {
        let input: AVCaptureDeviceInput
        do {
            input = try AVCaptureDeviceInput(device: device)
        } catch {
            throw CameraError(loc("The camera didn't start. Another app may be using it: close it, or choose another camera, and try again."))
        }
        let output = AVCaptureVideoDataOutput()
        output.videoSettings = [kCVPixelBufferPixelFormatTypeKey as String: kCVPixelFormatType_32BGRA]
        output.alwaysDiscardsLateVideoFrames = true
        output.setSampleBufferDelegate(self, queue: queue)
        session.beginConfiguration()
        defer { session.commitConfiguration() }
        guard session.canAddInput(input), session.canAddOutput(output) else {
            throw CameraError(loc("The camera didn't start. Another app may be using it: close it, or choose another camera, and try again."))
        }
        session.addInput(input)
        session.addOutput(output)
        try device.lockForConfiguration()
        device.activeFormat = format
        device.unlockForConfiguration()
    }

    public func captureOutput(_ output: AVCaptureOutput, didOutput sampleBuffer: CMSampleBuffer, from connection: AVCaptureConnection) {
        let (number, wanted): (Int64, [CheckedContinuation<CameraFrame?, Never>]) = lock.withLock {
            frames += 1
            let wanted = waiting.map(\.continuation)
            waiting = []
            return (frames, wanted)
        }
        guard let pixels = CMSampleBufferGetImageBuffer(sampleBuffer) else {
            wanted.forEach { $0.resume(returning: nil) }
            return
        }
        let (w, h) = (CVPixelBufferGetWidth(pixels), CVPixelBufferGetHeight(pixels))
        lock.withLock { frameSize = (w, h) }
        guard !wanted.isEmpty else { return }
        CVPixelBufferLockBaseAddress(pixels, .readOnly)
        defer { CVPixelBufferUnlockBaseAddress(pixels, .readOnly) }
        var picture: PrintCore.Picture?
        if CVPixelBufferGetPixelFormatType(pixels) == kCVPixelFormatType_32BGRA, let base = CVPixelBufferGetBaseAddress(pixels) {
            let row = CVPixelBufferGetBytesPerRow(pixels)
            let bytes = UnsafeBufferPointer(start: base.assumingMemoryBound(to: UInt8.self), count: row * h)
            picture = CameraFormats.rgb(bytes, w, h, bytesPerRow: row)
        }
        let frame = picture.map { CameraFrame($0, number) }
        wanted.forEach { $0.resume(returning: frame) }
    }

    public func capture() async -> CameraFrame? {
        let id = lock.withLock { () -> Int in
            nextId += 1
            return nextId
        }
        return await withTaskCancellationHandler {
            await withCheckedContinuation { (c: CheckedContinuation<CameraFrame?, Never>) in
                let refused: Bool = lock.withLock {
                    if closed || Task.isCancelled { return true }
                    waiting.append((id, c))
                    return false
                }
                if refused {
                    c.resume(returning: nil)
                    return
                }
                queue.asyncAfter(deadline: .now() + Self.frameWait) { [weak self] in self?.giveUp(id) }
            }
        } onCancel: {
            giveUp(id)
        }
    }

    private func giveUp(_ id: Int) {
        let c = lock.withLock { () -> CheckedContinuation<CameraFrame?, Never>? in
            guard let i = waiting.firstIndex(where: { $0.id == id }) else { return nil }
            return waiting.remove(at: i).continuation
        }
        c?.resume(returning: nil)
    }

    public func close() async {
        let pending = lock.withLock { () -> [CheckedContinuation<CameraFrame?, Never>] in
            closed = true
            let list = waiting.map(\.continuation)
            waiting = []
            return list
        }
        pending.forEach { $0.resume(returning: nil) }
        await withCheckedContinuation { (c: CheckedContinuation<Void, Never>) in
            queue.async {
                self.session.stopRunning() // the camera's light goes off
                c.resume()
            }
        }
    }
}
