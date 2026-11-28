import Foundation
import PrintCore

/// File › Export Pages as Images (Windows' `FileActions.ExportImages`): each chosen page as a PNG or JPEG in a folder,
/// named "name - page N.png" without replacing a file, at a resolution lowered for a page too large to stay under
/// `PageImages.maxPixels`; a page the engine refuses is left out and the rest saved; a cancel keeps the images before
/// it and deletes the one it stopped.
public enum PageImageExport {
    /// The Resolution choices, in dpi (Windows' list).
    public static let resolutions = [72, 96, 150, 200, 300, 600]
    /// 150 dpi, chosen first.
    public static let defaultResolution = 2

    /// A page's file name (Windows' `File_PageImageName`); `page` counts from 0.
    public static func fileName(_ name: String, page: Int, jpeg: Bool) -> String {
        loc("{0} - page {1}.{2}", name, page + 1, jpeg ? "jpg" : "png")
    }

    /// What will be written: each page's file and resolution, and the pages whose resolution was lowered.
    public struct Plan: Sendable {
        public let targets: [(page: Int, path: String)]
        /// Each page's resolution, `dpi` or lower.
        public let dpi: [Int: Double]
        public let requested: Int
        /// The pages exported below `requested`, in order.
        public let clamped: [Int]
        /// The lowest resolution among them (nil when none was lowered).
        public var lowest: Double? { clamped.compactMap { dpi[$0] }.min() }
    }

    /// Picks every file name before anything is written (none replaced, none twice).
    public static func plan(_ engine: PdfEngine, pages: [Int], folder: String, name: String, dpi: Int, jpeg: Bool) throws -> Plan {
        var resolution: [Int: Double] = [:]
        for p in pages where resolution[p] == nil { resolution[p] = PageImages.clampDpi(engine.page(p), Double(dpi)) }
        var reserved = Set<String>()
        var targets: [(page: Int, path: String)] = []
        for p in pages {
            let path = SplitFiles.uniquePath(folder, fileName(name, page: p, jpeg: jpeg), &reserved)
            reserved.insert(path.lowercased())
            targets.append((p, path))
        }
        let clamped = resolution.keys.sorted().filter { resolution[$0]! < Double(dpi) }
        return Plan(targets: targets, dpi: resolution, requested: dpi, clamped: clamped)
    }

    /// How a run ended: the images saved, the pages left out, and whether it was cancelled or stopped by an error.
    public struct Outcome: Sendable, Equatable {
        public var done = 0
        public var refused: [Int] = []
        public var cancelled = false
        /// What stopped it (nil: it ran to the end or was cancelled).
        public var failure: String?
    }

    public typealias Save = (PdfEngine, Int, Double, String, Bool, CancelToken?) throws -> Void

    /// Writes the plan's images in order; `progress(page, index, count)` before each. `save` stands in for
    /// `PdfEngine.saveImage` in tests.
    public static func run(_ engine: PdfEngine, _ plan: Plan, jpeg: Bool, cancel: CancelToken? = nil,
                           save: Save = { e, page, dpi, path, jpeg, cancel in try e.saveImage(page, dpi: dpi, path: path, jpeg: jpeg, cancel: cancel) },
                           progress: (Int, Int, Int) -> Void) -> Outcome {
        var outcome = Outcome()
        for (page, path) in plan.targets {
            if cancel?.isCancelled == true {
                outcome.cancelled = true
                return outcome
            }
            progress(page, outcome.done, plan.targets.count)
            do {
                try save(engine, page, plan.dpi[page] ?? Double(plan.requested), path, jpeg, cancel)
                outcome.done += 1
            } catch is CancellationError {
                try? FileManager.default.removeItem(atPath: path) // don't leave half an image behind
                outcome.cancelled = true
                return outcome
            } catch is PageRefused {
                outcome.refused.append(page) // a page that isn't shown isn't saved either: the rest are
            } catch {
                try? FileManager.default.removeItem(atPath: path)
                outcome.failure = (error as? PdfEngineError)?.message ?? "\(error)"
                return outcome
            }
        }
        return outcome
    }
}
