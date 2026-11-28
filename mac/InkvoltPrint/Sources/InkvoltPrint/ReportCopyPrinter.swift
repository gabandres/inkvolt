import Foundation
import PrintCore

/// `--report … --demo --copy-printer` (roadmap 3.3): the demo HP laser's own copier as Copy on the Printer… finds it (reading
/// only) and asks it to copy once; the made-up printer takes the PUT and forgets it, so nothing is copied.
extension Report {
    static func copyPrinterCheck(_ model: AppModel) async -> [String] {
        guard let laser = model.printers.first(where: { $0.id == Demo.uuid }) else { return ["copy-printer: no demo HP laser"] }
        for _ in 0..<100 where laser.printerCopier == nil { try? await Task.sleep(for: .milliseconds(100)) }
        guard let copier = laser.printerCopier else { return ["copy-printer: the demo HP laser offers no copier"] }
        let copy = PrinterCopyModel(printer: laser)
        await copy.copy()
        return ["copy-printer: offered, the start \(copier.start.path.joined(separator: "/")) = \(copier.start.value); Copy: \(copy.step)"]
    }
}
