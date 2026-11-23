import Foundation

/// Demo mode's camera (roadmap 4.12; Windows' `DemoCameras`): one made-up document camera whose every frame is a page of
/// lines lying at an angle on a dark desk, 1920 × 1080, each frame numbered in turn, so Capture page makes pages that are
/// found and warped flat as a real camera's would be. Nothing is read from a real camera.
public struct DemoCameras: Cameras {
    public static let camera = CameraInfo(id: "demo-camera", name: "Demo document camera")

    public init() {}

    public func list() async -> [CameraInfo] { [Self.camera] }

    public func open(_ camera: CameraInfo) async throws -> any CameraFeed { DemoCameraFeed() }

    /// The page on the desk: a sheet of Letter proportions seen a little from one side (wider at the bottom), lines of
    /// "text" across it.
    public static func frame(width: Int = 1920, height: Int = 1080) -> Picture {
        let (w, h) = (Double(width), Double(height))
        let corners = [(w * 0.36, h * 0.08), (w * 0.64, h * 0.08), (w * 0.70, h * 0.94), (w * 0.30, h * 0.94)]
        var px = [UInt8](repeating: 0, count: width * height * 3)
        func inside(_ x: Double, _ y: Double) -> Bool {
            for i in 0..<4 {
                let (a, b) = (corners[i], corners[(i + 1) % 4])
                if (b.0 - a.0) * (y - a.1) - (b.1 - a.1) * (x - a.0) < 0 { return false }
            }
            return true
        }
        for y in 0..<height {
            let fy = Double(y) / h
            for x in 0..<width {
                let (r, g, b): (UInt8, UInt8, UInt8)
                if inside(Double(x) + 0.5, Double(y) + 0.5) {
                    let text = fy > 0.18 && fy < 0.82 && abs(Double(x) / w - 0.5) < 0.09 && y % 30 < 4
                    (r, g, b) = text ? (40, 40, 48) : (238, 236, 230)
                } else {
                    (r, g, b) = (70, 52, 40) // a wooden desk
                }
                let i = (y * width + x) * 3
                px[i] = r
                px[i + 1] = g
                px[i + 2] = b
            }
        }
        return Picture(px, width, height, 3)
    }
}

/// The demo camera streaming: the same made-up frame, numbered in turn.
public final class DemoCameraFeed: CameraFeed, @unchecked Sendable {
    private let lock = NSLock()
    private var number: Int64 = 0
    private var closed = false
    private let picture = DemoCameras.frame()

    public init() {}

    public var size: (width: Int, height: Int) { (picture.width, picture.height) }

    public func capture() async -> CameraFrame? {
        lock.withLock {
            guard !closed else { return nil }
            number += 1
            return CameraFrame(picture, number)
        }
    }

    public func close() async { lock.withLock { closed = true } }
}
