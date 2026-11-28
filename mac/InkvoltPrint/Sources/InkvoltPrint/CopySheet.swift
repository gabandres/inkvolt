import AppKit
import PrintCore
import SwiftUI

/// The Print menu's Copy… (the Windows app's Copy tab, page copy): the options on the left, the sheets as they print on the
/// right, the buttons below. `CopyModel` does the work.
struct CopySheet: View {
    @State private var model: CopyModel
    @Environment(\.dismiss) private var dismiss

    init(printer: PrinterModel, app: AppModel) {
        _model = State(initialValue: CopyModel(printer: printer, app: app))
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            Text("Copy").font(.title2.weight(.semibold))
            if let reason = model.unavailableReason {
                Label(reason, systemImage: "exclamationmark.triangle").fixedSize(horizontal: false, vertical: true)
            }
            HStack(alignment: .top, spacing: 20) {
                options.frame(width: 260, alignment: .leading)
                preview
            }
            if let message = model.message {
                Text(message).foregroundStyle(model.messageIsError ? .red : .primary).fixedSize(horizontal: false, vertical: true)
            }
            Text(model.summary).foregroundStyle(.secondary)
            buttons
        }
        .padding(20)
        .frame(width: 700)
        .task { await model.shown() }
    }

    private var options: some View {
        @Bindable var model = model
        return Form {
            if model.showSource {
                Picker("Source", selection: $model.source) {
                    ForEach(model.sources, id: \.self) { Text(ScanChoices.sourceLabel($0)).tag($0) }
                }
            }
            Stepper(value: $model.copies, in: 1...CopyRoute.maxCopies) {
                HStack {
                    Text("Copies")
                    TextField("Copies", value: $model.copies, format: .number).frame(width: 44).labelsHidden()
                }
            }
            if model.showCollate {
                Toggle("Collate (1 2 3, 1 2 3)", isOn: $model.collate)
                    .help("Each copy comes out whole, in page order. Off: all the copies of page 1, then of page 2, and so on.")
            }
            Picker("Size", selection: $model.fitToPaper) {
                Text("Actual size").tag(false).help("The copy is the size of the original. Pages larger than the paper shrink to fit.")
                Text("Fit to paper").tag(true).help("Enlarges or shrinks each page to fill the paper, such as a receipt made easier to read")
            }
            .pickerStyle(.radioGroup)
            Picker("Pages per sheet", selection: $model.pagesPerSheet) {
                ForEach(CopyLayout.pagesPerSheetChoices, id: \.self) { n in
                    Text(n == 1 ? String(localized: "One page per sheet") : String(localized: "\(n) pages per sheet")).tag(n)
                }
            }
            Toggle("Color copy", isOn: $model.isColor)
                .help("Scans in color. Black-and-white printers print it in shades of grey either way.")
            if model.showTwoSided {
                Toggle(model.twoSidedText, isOn: $model.twoSided)
                    .help(model.canTwoSided ? model.twoSidedText
                          : String(localized: "This printer can't print both sides by itself: it prints the fronts, then you put the stack back and it prints the backs"))
            }
            Toggle("Preview before printing", isOn: $model.previewFirst)
                .help("Scans, shows each sheet as it will print, then waits for you to click Print.")
        }
        .disabled(model.isBusy)
    }

    private var preview: some View {
        ScrollView(.horizontal) {
            HStack(alignment: .top, spacing: 12) {
                if model.sheets.isEmpty {
                    Text(model.hint).foregroundStyle(.secondary).frame(width: 300, height: 300).multilineTextAlignment(.center)
                }
                ForEach(model.sheets) { sheet in SheetPreview(sheet: sheet, height: 300) }
            }
            .padding(4)
        }
        .frame(height: 316)
        .accessibilityLabel("Copy preview")
    }

    private var buttons: some View {
        HStack {
            if model.isBusy { ProgressView().controlSize(.small) }
            Spacer()
            Button("Close") { dismiss() }.keyboardShortcut(.cancelAction).disabled(model.isBusy)
            if model.canCancel { Button("Cancel") { model.cancel() } }
            if !model.sheets.isEmpty || model.canPrintAgain { Button("Start Over") { model.startOver() }.disabled(model.isBusy) }
            if model.canPrintAgain { Button("Print Again") { model.printAgainNow() }.disabled(model.isBusy) }
            if model.awaitingPrint {
                Button("Print") { model.printPreviewed() }.buttonStyle(.borderedProminent).disabled(model.isBusy)
            }
            Button("Copy") { model.copy() }
                .buttonStyle(.borderedProminent).keyboardShortcut(.defaultAction).disabled(!model.canCopy)
        }
    }
}

/// A sheet of the preview: white paper at `height` points tall, its pages where they print.
private struct SheetPreview: View {
    let sheet: CopyModel.PreviewSheet
    let height: Double

    var body: some View {
        let k = height / sheet.paperHeight
        ZStack(alignment: .topLeading) {
            Rectangle().fill(.white)
            ForEach(sheet.pages) { page in
                Group {
                    if let image = page.image {
                        // Drawn unturned in the turned box's size, then turned a quarter clockwise into place.
                        Image(nsImage: image).resizable()
                            .frame(width: (page.rotated ? page.at.height : page.at.width) * k, height: (page.rotated ? page.at.width : page.at.height) * k)
                            .rotationEffect(.degrees(page.rotated ? 90 : 0))
                    } else {
                        Rectangle().stroke(style: StrokeStyle(lineWidth: 1, dash: [4]))
                            .frame(width: page.at.width * k, height: page.at.height * k)
                    }
                }
                .frame(width: page.at.width * k, height: page.at.height * k)
                .offset(x: page.at.x * k, y: page.at.y * k)
            }
        }
        .frame(width: sheet.paperWidth * k, height: height)
        .clipped()
        .overlay(Rectangle().stroke(.separator))
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(String(localized: "Sheet \(sheet.id + 1): \(sheet.pages.count) scanned pages"))
    }
}
