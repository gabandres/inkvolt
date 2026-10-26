import AppKit
import Observation
import PDFKit
import PrintCore
import PrintMac
import SwiftUI

/// The ID card copy (the Windows app's Copy tab, ID card part): the front scanned from the glass's corner, the card turned
/// over, the back scanned, then both sides on one sheet at actual size through the print panel.
@MainActor @Observable
final class IdCardCopyModel {
    enum Step { case front, back, done }

    private(set) var step = Step.front
    private(set) var front: NSImage?
    private(set) var back: NSImage?
    private(set) var isScanning = false
    private(set) var problem: String?
    var color = true

    @ObservationIgnored private var frontSide: IdCardSheet.Side?
    @ObservationIgnored private var backSide: IdCardSheet.Side?
    @ObservationIgnored private let printer: PrinterModel
    @ObservationIgnored private let app: AppModel

    init(printer: PrinterModel, app: AppModel) {
        self.printer = printer
        self.app = app
    }

    var hint: String {
        switch step {
        case .front: "Put the card face down in the corner of the scanner glass (by the arrow mark), then click Scan Front. You'll turn it over halfway."
        case .back: "Turn the card over in the same corner of the glass, then click Scan Back."
        case .done: "Both sides are on one sheet, at actual size. Print again, or start over with another card."
        }
    }

    /// Scans the side the step asks for; after the back, prints (unless `printWhenDone` is off: `--report`).
    func scanSide(printWhenDone: Bool = true) async {
        guard !isScanning, step != .done else { return }
        isScanning = true
        problem = nil
        defer { isScanning = false }
        guard let scanner = await printer.scanner() else {
            problem = "The scanner isn't available while the printer isn't connected."
            return
        }
        let caps = try? await scanner.capabilities()
        let offered = caps.map { ScanChoices.resolutions($0, .platen) } ?? [300]
        let dpi = offered.min { abs($0 - 300) < abs($1 - 300) } ?? 300
        let request = CopyLayout.idCardRequest(color ? .color : .grayscale, dpi)
        do {
            var page: [UInt8]?
            for try await jpeg in scanner.scan(request) where page == nil { page = jpeg }
            guard let page, let image = NSImage(data: Data(page)) else {
                problem = "No page came from the scanner."
                return
            }
            let side = IdCardSheet.Side(jpeg: page, dpi: ScanModel.dpi(of: page, asked: dpi, widthIn300ths: CopyLayout.idCardScanWidth))
            if step == .front {
                frontSide = side
                front = image
                step = .back
            } else {
                backSide = side
                back = image
                step = .done
                if printWhenDone { print() }
            }
        } catch let e as ScanError {
            problem = e.description
        } catch {
            problem = "The scan didn't finish: the scanner stopped answering."
        }
    }

    /// The paper the sheet is laid out on: Letter or A4, by region (points).
    static var paper: CGSize { Locale.current.measurementSystem == .metric ? CGSize(width: 595, height: 842) : CGSize(width: 612, height: 792) }

    /// The sheet as it prints.
    var document: PDFDocument? {
        guard let frontSide, let backSide, let data = IdCardSheet.pdf(front: frontSide, back: backSide, paper: Self.paper) else { return nil }
        return PDFDocument(data: data)
    }

    /// Both sides on Letter or A4 (by region), through the print panel at actual size.
    func print() {
        let paper = Self.paper
        guard let document else {
            problem = "The copy couldn't be prepared for printing."
            return
        }
        Printing.print(document, name: "ID card copy", on: printer, app: app, actualSize: true, paper: NSSize(width: paper.width, height: paper.height))
    }

    func startOver() {
        step = .front
        front = nil
        back = nil
        frontSide = nil
        backSide = nil
        problem = nil
    }
}

struct IdCardCopySheet: View {
    @State private var model: IdCardCopyModel
    @Environment(\.dismiss) private var dismiss

    init(printer: PrinterModel, app: AppModel) {
        _model = State(initialValue: IdCardCopyModel(printer: printer, app: app))
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            Text("Copy an ID Card").font(.title2.weight(.semibold))
            Text(model.hint).fixedSize(horizontal: false, vertical: true)
            // The sheet as it prints: front on the top half, back on the bottom half.
            VStack(spacing: 0) {
                half(model.front, "Front")
                Divider()
                half(model.back, model.step == .back ? "Back: turn the card over" : "Back")
            }
            .frame(width: 300, height: 388)
            .background(.white)
            .overlay(Rectangle().stroke(.separator))
            .frame(maxWidth: .infinity)
            if let problem = model.problem { Text(problem).foregroundStyle(.red).fixedSize(horizontal: false, vertical: true) }
            HStack {
                Toggle("Color", isOn: $model.color).disabled(model.step != .front)
                Spacer()
                if model.isScanning { ProgressView().controlSize(.small) }
                Button("Close") { dismiss() }.keyboardShortcut(.cancelAction)
                if model.step != .front { Button("Start Over") { model.startOver() }.disabled(model.isScanning) }
                if model.step == .done {
                    Button("Print Again") { model.print() }.buttonStyle(.borderedProminent)
                } else {
                    Button(model.step == .front ? "Scan Front" : "Scan Back") { Task { await model.scanSide() } }
                        .buttonStyle(.borderedProminent).keyboardShortcut(.defaultAction).disabled(model.isScanning)
                }
            }
        }
        .padding(20)
        .frame(width: 460)
    }

    private func half(_ image: NSImage?, _ label: String) -> some View {
        ZStack {
            if let image {
                Image(nsImage: image).resizable().aspectRatio(contentMode: .fit).padding(16)
            } else {
                Text(label).foregroundStyle(.secondary)
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(image == nil ? "\(label), not scanned yet" : "\(label), scanned")
    }
}
