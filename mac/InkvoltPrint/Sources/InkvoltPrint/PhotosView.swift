import AppKit
import Observation
import PDFKit
import PrintCore
import PrintMac
import SwiftUI
import UniformTypeIdentifiers

/// One picture to print: its file, how it's turned, how many prints.
struct PhotoItem: Identifiable {
    let id = UUID()
    let url: URL
    var image: CGImage
    var quarterTurns = 0
    var copies = 1
    var name: String { url.lastPathComponent }
}

/// Paper the photos are laid out on (the print panel's own paper choice doesn't move them).
enum PhotoPaper: String, CaseIterable, Identifiable {
    case letter, a4, photo4x6, photo5x7
    var id: String { rawValue }

    var label: String {
        switch self {
        case .letter: "Letter (8.5 × 11 in)"
        case .a4: "A4 (210 × 297 mm)"
        case .photo4x6: "4 × 6 in photo paper"
        case .photo5x7: "5 × 7 in photo paper"
        }
    }

    /// Inches, with the margins most printers keep (borderless printing isn't asked for).
    var sheet: SheetPaper {
        switch self {
        case .letter: SheetPaper(8.5, 11, 0.25, 0.25, 0.25, 0.25)
        case .a4: SheetPaper(210 / 25.4, 297 / 25.4, 0.25, 0.25, 0.25, 0.25)
        case .photo4x6: SheetPaper(4, 6, 0.12, 0.12, 0.12, 0.12)
        case .photo5x7: SheetPaper(5, 7, 0.12, 0.12, 0.12, 0.12)
        }
    }

    var pageSize: NSSize { NSSize(width: sheet.width * 72, height: sheet.height * 72) }
}

/// Print Photos (the Windows app's Photos tab): pictures laid out full page, at a print size, or as a contact sheet,
/// previewed sheet by sheet, then printed at their real size through the print panel.
@MainActor @Observable
final class PhotosModel {
    var photos: [PhotoItem] = []
    var kind: PhotoLayoutKind = .printSize
    var sizeName = PhotoSizes.in4x6.name
    var fit: PhotoFit = .fill
    var onePhotoPerSheet = false
    var perSheet = 12
    var paper: PhotoPaper = Locale.current.measurementSystem == .metric ? .a4 : .letter
    private(set) var problem: String?
    private(set) var previews: [NSImage] = []
    private(set) var printing = false

    @ObservationIgnored private let printer: PrinterModel
    @ObservationIgnored private let app: AppModel

    init(printer: PrinterModel, app: AppModel) {
        self.printer = printer
        self.app = app
    }

    var options: PhotoLayoutOptions {
        PhotoLayoutOptions(kind: kind, size: PhotoSizes.all.first { $0.name == sizeName } ?? PhotoSizes.in4x6, perSheet: perSheet, fit: fit,
                           onePhotoPerSheet: onePhotoPerSheet)
    }

    var sheets: [PhotoSheet] {
        PhotoLayout.sheets(photos.map { PhotoInput(Double($0.image.width), Double($0.image.height), $0.copies, .none) }, options, paper.sheet)
    }

    func add() {
        let panel = NSOpenPanel()
        panel.allowedContentTypes = [.image]
        panel.allowsMultipleSelection = true
        panel.message = "Choose the photos to print."
        guard panel.runModal() == .OK else { return }
        problem = nil
        var unreadable = 0
        for url in panel.urls {
            let accessing = url.startAccessingSecurityScopedResource()
            defer { if accessing { url.stopAccessingSecurityScopedResource() } }
            if let image = try? PhotoSheets.load(url) { photos.append(PhotoItem(url: url, image: image)) } else { unreadable += 1 }
        }
        if unreadable > 0 { problem = unreadable == 1 ? "One file couldn't be read as a picture." : "\(unreadable) files couldn't be read as pictures." }
        refresh()
    }

    func turn(_ id: UUID, _ quarters: Int) {
        guard let i = photos.firstIndex(where: { $0.id == id }), let turned = try? PhotoSheets.load(photos[i].url, quarterTurns: photos[i].quarterTurns + quarters)
        else { return }
        photos[i].quarterTurns += quarters
        photos[i].image = turned
        refresh()
    }

    func remove(_ id: UUID) {
        photos.removeAll { $0.id == id }
        refresh()
    }

    /// The sheets' previews, redrawn after each change.
    func refresh() {
        let sheets = sheets, images = photos.map(\.image), names = photos.map(\.name), paper = paper.sheet
        previews = sheets.prefix(12).compactMap { sheet in
            PhotoSheets.preview(sheet, photos: images, names: names, paper: paper, width: 360).map { NSImage(cgImage: $0, size: NSSize(width: $0.width, height: $0.height)) }
        }
    }

    func print() async {
        let sheets = sheets
        guard !sheets.isEmpty else { return }
        printing = true
        defer { printing = false }
        let images = photos.map(\.image), names = photos.map(\.name), sheet = paper.sheet
        let data: Data? = await offPool { try? PhotoSheets.pdf(sheets, photos: images, names: names, paper: sheet) }
        guard let data, let document = PDFDocument(data: data) else {
            problem = "The sheets couldn't be prepared for printing."
            return
        }
        Printing.print(document, name: photos.count == 1 ? photos[0].name : "\(photos.count) photos", on: printer, app: app, actualSize: true,
                       paper: paper.pageSize)
    }
}

struct PhotosView: View {
    @State private var model: PhotosModel
    @Environment(\.dismiss) private var dismiss

    init(printer: PrinterModel, app: AppModel) { _model = State(initialValue: PhotosModel(printer: printer, app: app)) }

    var body: some View {
        @Bindable var model = model
        HStack(alignment: .top, spacing: 0) {
            Form {
                Section("Photos") {
                    ForEach(model.photos) { p in
                        HStack {
                            Image(decorative: p.image, scale: max(CGFloat(p.image.width) / 48, 1)).frame(width: 48, height: 48)
                            Text(p.name).lineLimit(1).truncationMode(.middle)
                            Spacer()
                            Stepper("\(p.copies)", value: Binding(get: { p.copies }, set: { v in
                                if let i = model.photos.firstIndex(where: { $0.id == p.id }) { model.photos[i].copies = v }
                                model.refresh()
                            }), in: 1...99).fixedSize()
                            Button { model.turn(p.id, 1) } label: { Image(systemName: "rotate.right") }.buttonStyle(.borderless).help("Turn right")
                            Button { model.remove(p.id) } label: { Image(systemName: "trash") }.buttonStyle(.borderless).help("Remove")
                        }
                    }
                    Button("Add Photos…") { model.add() }
                    if let problem = model.problem { Text(problem).foregroundStyle(.red) }
                }
                Section("Layout") {
                    Picker("Paper", selection: $model.paper) { ForEach(PhotoPaper.allCases) { Text($0.label).tag($0) } }
                    Picker("Layout", selection: $model.kind) {
                        Text("Full page").tag(PhotoLayoutKind.fullPage)
                        Text("Print size").tag(PhotoLayoutKind.printSize)
                        Text("Contact sheet").tag(PhotoLayoutKind.contactSheet)
                    }
                    if model.kind == .printSize {
                        Picker("Size", selection: $model.sizeName) { ForEach(PhotoSizes.all, id: \.name) { Text($0.name).tag($0.name) } }
                        Toggle("A whole sheet of each photo", isOn: $model.onePhotoPerSheet)
                    }
                    if model.kind == .contactSheet {
                        Stepper("\(model.perSheet) per sheet", value: $model.perSheet, in: 6...48, step: 6)
                    } else {
                        Picker("Fit", selection: $model.fit) {
                            Text("Fill the print (crops the edges)").tag(PhotoFit.fill)
                            Text("Whole photo").tag(PhotoFit.fit)
                        }
                    }
                }
            }
            .formStyle(.grouped)
            .frame(width: 380)
            .onChange(of: model.options) { model.refresh() }
            .onChange(of: model.paper) { model.refresh() }
            Divider()
            VStack(spacing: 0) {
                ScrollView {
                    LazyVGrid(columns: [GridItem(.adaptive(minimum: 200), spacing: 16)], spacing: 16) {
                        ForEach(Array(model.previews.enumerated()), id: \.offset) { i, image in
                            VStack(spacing: 4) {
                                Image(nsImage: image).resizable().aspectRatio(contentMode: .fit).shadow(radius: 2)
                                Text("Sheet \(i + 1)").font(.caption).foregroundStyle(.secondary)
                            }
                        }
                    }
                    .padding(16)
                }
                .overlay { if model.photos.isEmpty { ContentUnavailableView("No photos yet", systemImage: "photo.on.rectangle", description: Text("Add the photos to print.")) } }
                Divider()
                HStack {
                    Text(model.sheets.count == 1 ? "1 sheet" : "\(model.sheets.count) sheets").foregroundStyle(.secondary)
                    Spacer()
                    if model.printing { ProgressView().controlSize(.small) }
                    Button("Close") { dismiss() }.keyboardShortcut(.cancelAction)
                    Button("Print…") { Task { await model.print() } }.buttonStyle(.borderedProminent).disabled(model.sheets.isEmpty || model.printing)
                }
                .padding(12)
            }
        }
        .frame(minWidth: 860, minHeight: 560)
    }
}

