import AppKit
import PrintCore
import SwiftUI
import UniformTypeIdentifiers

/// A printer's Scan tab: the settings beside the scanned pages, then Save.
struct ScanView: View {
    let scan: ScanModel
    let leftOver: [LeftOverScan]
    @Environment(AppModel.self) private var app
    @State private var cropping: String?
    @State private var photos: String?

    var body: some View {
        HStack(alignment: .top, spacing: 0) {
            ScanSettings(scan: scan).frame(width: 270)
            Divider()
            VStack(spacing: 0) {
                ForEach(leftOver, id: \.listPath) { left in
                    RestoreBanner(left: left) {
                        scan.restore(left)
                        app.leftOverScans.removeAll { $0.listPath == left.listPath }
                    } discard: {
                        ScanRecoveryStore.remove(left)
                        app.leftOverScans.removeAll { $0.listPath == left.listPath }
                    }
                }
                if scan.pages.isEmpty {
                    ContentUnavailableView("No pages yet", systemImage: "doc.viewfinder",
                                           description: Text(scan.isScanning ? "The first page is on its way." : "Put a page on the glass or pages in the feeder, then click Scan."))
                } else {
                    PageGrid(scan: scan, cropping: $cropping, photos: $photos)
                }
                Divider()
                SaveBar(scan: scan)
            }
        }
        .task { await scan.load() }
        .sheet(item: Binding(get: { cropping.map(CropTarget.init) }, set: { cropping = $0?.id })) { target in
            CropSheet(scan: scan, id: target.id)
        }
        .sheet(item: Binding(get: { photos.map(CropTarget.init) }, set: { photos = $0?.id })) { target in
            PhotosSheet(scan: scan, id: target.id)
        }
        .onChange(of: app.paneRequest, initial: true) { _, request in
            if request == .photosSheet {
                photos = scan.pages.pages.first(where: \.hasPhotos)?.id
            } else if request != nil {
                photos = nil
            }
        }
    }
}

private struct CropTarget: Identifiable { let id: String }

private struct ScanSettings: View {
    @Bindable var scan: ScanModel

    var body: some View {
        Form {
            PresetStrip(scan: scan)
            if let error = scan.loadError {
                Text(error).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
                Button("Try Again") { Task { await scan.load() } }
            }
            Picker("Source", selection: $scan.source) {
                ForEach(scan.sources, id: \.self) { Text(ScanChoices.sourceLabel($0)).tag($0) }
            }
            Picker("Color", selection: $scan.color) {
                ForEach(scan.colors, id: \.self) { Text($0 == .color ? "Color" : "Grayscale").tag($0) }
            }
            Picker("Resolution", selection: $scan.dpi) {
                ForEach(scan.resolutions, id: \.self) { Text("\($0) dpi").tag($0) }
            }
            Picker("Size", selection: $scan.sizeKey) {
                ForEach(scan.sizes, id: \.key) { Text($0.label).tag($0.key) }
            }
            Picker("Save as", selection: $scan.format) {
                ForEach(ScanFormat.allCases) { Text($0.label).tag($0) }
            }
            Toggle("Skip blank pages", isOn: $scan.skipBlank)
            Toggle("Straighten pages", isOn: $scan.straighten)
            if scan.source == .platen {
                Toggle("Several photos on the glass", isOn: $scan.findPhotos)
                    .help("Each photo laid on the glass is found and saved as its own picture, cut out straight")
            } else {
                Picker("Split into files at", selection: $scan.splitAt) {
                    ForEach(SplitAt.known, id: \.self) { Text(Separators.label($0)).tag($0) }
                }
                .help("One feeder run saved as several files: a new file starts at each separator sheet")
                if scan.splitAt != .none {
                    Toggle("Keep separator sheets", isOn: $scan.keepSeparators)
                        .help("Keep each separator sheet as the first page of the file it starts")
                    if scan.splitAt != .blankPage {
                        Button("Print a Separator Sheet…") { scan.printSeparatorSheet() }
                            .help("A Patch T sheet to put in front of each document in the feeder; print it at actual size")
                    }
                }
            }
            HStack {
                if scan.isScanning {
                    ProgressView().controlSize(.small)
                    Button("Stop") { scan.stop() }
                } else {
                    Button(scan.pages.isEmpty ? "Scan" : "Scan More") { scan.scan() }
                        .keyboardShortcut("r", modifiers: .command)
                        .buttonStyle(.borderedProminent)
                        .disabled(scan.caps == nil)
                }
            }
        }
        .formStyle(.grouped)
        .disabled(scan.isSaving)
    }
}

private struct RestoreBanner: View {
    let left: LeftOverScan
    let restore: () -> Void
    let discard: () -> Void

    var body: some View {
        HStack {
            Label("\(left.scan.pages.count) scanned \(left.scan.pages.count == 1 ? "page" : "pages") from \(left.scan.savedUtc.formatted(date: .abbreviated, time: .shortened)) weren't saved.",
                  systemImage: "clock.arrow.circlepath")
            Spacer()
            Button("Restore") { restore() }
            Button("Discard") { discard() }
        }
        .padding(10)
        .background(.yellow.opacity(0.15))
    }
}

private struct PageGrid: View {
    let scan: ScanModel
    @Binding var cropping: String?
    @Binding var photos: String?

    var body: some View {
        ScrollView {
            LazyVGrid(columns: [GridItem(.adaptive(minimum: 170), spacing: 14)], spacing: 14) {
                let starts = scan.pages.fileStarts
                ForEach(scan.pages.pages) { page in
                    PageTile(scan: scan, page: page, file: starts[page.id] ?? 0, cropping: $cropping, photos: $photos)
                }
            }
            .padding(14)
        }
    }
}

private struct PageTile: View {
    let scan: ScanModel
    let page: ScannedPage
    /// The file this page starts (0: none, or only one file).
    let file: Int
    @Binding var cropping: String?
    /// The page whose photos are being adjusted (a scan of the glass that was looked for photos).
    @Binding var photos: String?

    var body: some View {
        let number = scan.pages.number(page.id) ?? 0
        VStack(spacing: 6) {
            ZStack {
                if let image = scan.thumbnails[page.id] {
                    Image(nsImage: image).resizable().interpolation(.high).aspectRatio(contentMode: .fit)
                        .shadow(radius: 1)
                        .overlay { if let photos = page.photos, !photos.isEmpty { PhotoBoxes(photos: photos) } }
                } else {
                    Rectangle().fill(.background.secondary).aspectRatio(0.77, contentMode: .fit).overlay { ProgressView().controlSize(.small) }
                }
            }
            .frame(height: 200)
            .opacity(page.skipped || (page.isSeparator && !scan.pages.keepSeparators) ? 0.35 : 1)
            .onTapGesture(count: 2) { if page.photos != nil { photos = page.id } else { cropping = page.id } }
            HStack(spacing: 4) {
                if file > 0 {
                    Text("File \(file)").font(.caption.weight(.semibold)).padding(.horizontal, 5).padding(.vertical, 1)
                        .background(.tint.opacity(0.2), in: .capsule)
                }
                Text("\(number)").font(.caption.monospacedDigit().weight(.semibold))
                if !page.note.isEmpty { Text(page.note).font(.caption).foregroundStyle(.secondary) }
            }
            HStack(spacing: 2) {
                Button { scan.turn(page.id, -1) } label: { Image(systemName: "rotate.left") }.help("Turn left")
                Button { scan.turn(page.id, 1) } label: { Image(systemName: "rotate.right") }.help("Turn right")
                if page.photos != nil {
                    Button { photos = page.id } label: { Image(systemName: "photo.on.rectangle") }.help("Photos")
                } else {
                    Button { cropping = page.id } label: { Image(systemName: "crop") }.help("Crop")
                }
                if page.skipped {
                    Button("Keep") { scan.keepPage(page.id) }
                } else {
                    Button { scan.delete(page.id) } label: { Image(systemName: "trash") }.help("Delete")
                }
            }
            .buttonStyle(.borderless)
        }
        .padding(8)
        .background(.background.secondary.opacity(0.5), in: .rect(cornerRadius: 8))
        .contextMenu {
            Button("Turn Left") { scan.turn(page.id, -1) }
            Button("Turn Right") { scan.turn(page.id, 1) }
            // A page of photos is never saved itself: each photo is cut out (Turn turns them all).
            if !page.hasPhotos {
                Button("Crop…") { cropping = page.id }
                if !page.edits.isEmpty { Button("Undo Edits") { scan.reset(page.id) } }
            }
            if page.photos != nil {
                Button("Photos…") { photos = page.id }
                Button("Find Photos Again") { Task { await scan.findPhotosAgain(page.id) } }
                if page.hasPhotos { Button("Save the Whole Scan") { scan.setPhotos(page.id, []) } }
            }
            Divider()
            if page.isSeparator {
                Button("Not a Separator") { scan.notSeparator(page.id) }
            } else {
                Button(page.startsFile ? "Don't Start a New File Here" : "Start a New File Here") { scan.toggleStartsFile(page.id) }
                    .disabled(number <= 1)
                Button("Use as a Separator Sheet") { scan.useAsSeparator(page.id) }
            }
            Divider()
            Button("Move Earlier") { scan.move(page.id, by: -1) }.disabled(number <= 1)
            Button("Move Later") { scan.move(page.id, by: 1) }.disabled(number >= scan.pages.pages.count)
            Divider()
            if page.skipped { Button("Keep") { scan.keepPage(page.id) } } else { Button("Don't Save") { scan.skipPage(page.id) } }
            Button("Delete", role: .destructive) { scan.delete(page.id) }
        }
        .accessibilityElement(children: .contain)
        .accessibilityLabel(label(number))
        .draggable(page.id)
        .dropDestination(for: String.self) { ids, _ in
            guard let id = ids.first, id != page.id, let to = scan.pages.number(page.id) else { return false }
            scan.move(id, to: to - 1)
            return true
        }
    }
}

extension PageTile {
    fileprivate func label(_ number: Int) -> String {
        let start = file > 0 ? ", starts file \(file)" : ""
        return page.note.isEmpty ? "Page \(number)\(start)" : "Page \(number)\(start), \(page.note.lowercased())"
    }
}

/// The photos found on the glass, outlined and numbered on the page's thumbnail (boxes in units of the scan's width, y down).
private struct PhotoBoxes: View {
    let photos: [PhotoBox]

    var body: some View {
        GeometryReader { geo in
            let scale = geo.size.width
            ForEach(Array(photos.enumerated()), id: \.offset) { i, box in
                let corners = box.corners().map { CGPoint(x: $0.x * scale, y: $0.y * scale) }
                Path { path in path.addLines(corners); path.closeSubpath() }
                    .stroke(Color.accentColor, lineWidth: 2)
                Text("\(i + 1)").font(.caption2.weight(.bold)).foregroundStyle(.white)
                    .padding(3).background(Color.accentColor, in: .circle)
                    .position(x: box.centerX * scale, y: box.centerY * scale)
            }
        }
        .accessibilityHidden(true)
    }
}

private struct SaveBar: View {
    let scan: ScanModel

    var body: some View {
        HStack(spacing: 10) {
            VStack(alignment: .leading, spacing: 2) {
                if let problem = scan.problem { Text(problem).foregroundStyle(.red).fixedSize(horizontal: false, vertical: true) }
                Text(scan.status).foregroundStyle(.secondary)
            }
            Spacer()
            if scan.isSaving { ProgressView().controlSize(.small) }
            Button("Clear") { scan.clear() }.disabled(scan.pages.isEmpty || scan.isScanning || scan.isSaving)
            Button("Print…") { Task { await scan.printPages() } }
                .help("Print the pages: a copy")
                .disabled(scan.pages.toSave.isEmpty || scan.isScanning || scan.isSaving)
            if let p = scan.preset {
                Button("Save (\(p.name))") { Task { await scan.saveWithPreset() } }
                    .disabled(scan.pages.toSave.isEmpty || scan.isScanning || scan.isSaving)
            }
            Button("Save…") { save() }
                .keyboardShortcut("s", modifiers: .command)
                .buttonStyle(.borderedProminent)
                .disabled(scan.pages.toSave.isEmpty || scan.isScanning || scan.isSaving)
        }
        .padding(12)
    }

    /// The save panel (a sandboxed app writes only where the user points): a file for a PDF or one image, a folder for several
    /// (a batch's files, or several images).
    private func save() {
        if scan.savesSeveralFiles {
            let files = scan.format == .jpeg ? scan.imagesPerFile.reduce(0, +) : scan.imagesPerFile.count
            let panel = NSOpenPanel()
            panel.canChooseDirectories = true
            panel.canChooseFiles = false
            panel.canCreateDirectories = true
            panel.prompt = "Save Here"
            panel.message = "Choose the folder for the \(files) \(scan.format == .jpeg ? "images" : "files")."
            guard panel.runModal() == .OK, let url = panel.url else { return }
            Task { await scan.save(to: url) }
            return
        }
        let panel = NSSavePanel()
        panel.allowedContentTypes = [scan.format == .jpeg ? .jpeg : .pdf]
        panel.nameFieldStringValue = scan.suggestedName
        panel.canCreateDirectories = true
        guard panel.runModal() == .OK, let url = panel.url else { return }
        Task { await scan.save(to: url) }
    }
}

/// Crop: the page enlarged; drag a box over the part to keep.
private struct CropSheet: View {
    let scan: ScanModel
    let id: String
    @Environment(\.dismiss) private var dismiss
    @State private var image: NSImage?
    @State private var box: CropBox = .full
    @State private var dragStart: CGPoint?

    var body: some View {
        VStack(spacing: 12) {
            Text("Drag over the part of the page to keep.").foregroundStyle(.secondary)
            GeometryReader { geo in
                if let image {
                    let fit = fitted(image.size, in: geo.size)
                    ZStack(alignment: .topLeading) {
                        Image(nsImage: image).resizable().frame(width: fit.width, height: fit.height)
                        Rectangle().fill(.black.opacity(0.35)).frame(width: fit.width, height: fit.height)
                            .mask {
                                Rectangle().overlay {
                                    Rectangle().frame(width: box.width * fit.width, height: box.height * fit.height)
                                        .position(x: (box.x + box.width / 2) * fit.width, y: (box.y + box.height / 2) * fit.height)
                                        .blendMode(.destinationOut)
                                }
                                .compositingGroup()
                            }
                        Rectangle().strokeBorder(.white, lineWidth: 2)
                            .frame(width: box.width * fit.width, height: box.height * fit.height)
                            .offset(x: box.x * fit.width, y: box.y * fit.height)
                    }
                    .frame(width: fit.width, height: fit.height)
                    .contentShape(Rectangle())
                    .gesture(DragGesture(minimumDistance: 4).onChanged { g in
                        let start = dragStart ?? g.startLocation
                        dragStart = start
                        let x0 = min(start.x, g.location.x) / fit.width, y0 = min(start.y, g.location.y) / fit.height
                        let x1 = max(start.x, g.location.x) / fit.width, y1 = max(start.y, g.location.y) / fit.height
                        box = CropBox(x0, y0, x1 - x0, y1 - y0).clamp()
                    }.onEnded { _ in dragStart = nil })
                    .position(x: geo.size.width / 2, y: geo.size.height / 2)
                } else {
                    ProgressView().position(x: geo.size.width / 2, y: geo.size.height / 2)
                }
            }
            .frame(minWidth: 520, minHeight: 620)
            HStack {
                Button("Whole Page") { box = .full }
                Spacer()
                Button("Cancel", role: .cancel) { dismiss() }.keyboardShortcut(.cancelAction)
                Button("Crop") {
                    scan.crop(id, shown: box)
                    dismiss()
                }
                .keyboardShortcut(.defaultAction)
            }
        }
        .padding(18)
        .task {
            box = scan.pages.page(id)?.edits.shownCrop ?? .full
            image = await scan.image(id)
        }
    }

    private func fitted(_ size: NSSize, in space: CGSize) -> CGSize {
        guard size.width > 0, size.height > 0 else { return space }
        let scale = min(space.width / size.width, space.height / size.height)
        return CGSize(width: size.width * scale, height: size.height * scale)
    }
}

/// Photos: the scan of the glass, large, with a box over each photo, each saved as its own picture. The boxes are moved,
/// resized and turned by hand, or drawn for a photo that wasn't found (`PhotoBoxEditor`; the Windows app's photo view).
private struct PhotosSheet: View {
    let scan: ScanModel
    let id: String
    @Environment(\.dismiss) private var dismiss
    @State private var image: NSImage?
    @State private var editor = PhotoBoxEditor(boxes: [], aspect: 1)
    @State private var widthInches = 8.5
    @State private var hover = PhotoBoxEditor.Grip.draw
    @State private var finding = false
    @FocusState private var focused: Bool

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text("Each box is saved as its own picture. Drag a box, its corners, or its round handle (the photo's top) to turn it; drag on the glass to mark a photo. Tab picks a box; arrows move it, Shift-arrows resize it, Option-arrows turn it, Delete removes it.")
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
            GeometryReader { geo in
                if let image {
                    let fit = fitted(image.size, in: geo.size)
                    glass(image, fit)
                        .position(x: geo.size.width / 2, y: geo.size.height / 2)
                } else {
                    ProgressView().position(x: geo.size.width / 2, y: geo.size.height / 2)
                }
            }
            .frame(minWidth: 660, idealWidth: 700, minHeight: 380, idealHeight: 500)
            Text(editor.status(widthInches: widthInches))
                .fixedSize(horizontal: false, vertical: true)
            HStack {
                Button("Add Photo") { change { $0.add() } }
                    .help("A box in the middle of the glass, for a photo that wasn't found")
                Button("Remove Photo") { change { $0.removeSelected() } }
                    .disabled(editor.selectedBox == nil)
                Button("Turn Saved Photo") { change { $0.turnSelected() } }
                    .help("Saves the selected photo turned a quarter clockwise")
                    .disabled(editor.selectedBox == nil)
                Button("Find Again") { findAgain() }
                    .help("Looks for the photos again, dropping the changes made here")
                    .disabled(finding)
                Spacer()
                Button("Cancel", role: .cancel) { dismiss() }.keyboardShortcut(.cancelAction)
                Button("Done") {
                    scan.setPhotos(id, editor.boxes)
                    dismiss()
                }
                .keyboardShortcut(.defaultAction)
            }
        }
        .padding(18)
        .task {
            let boxes = scan.pages.page(id)?.photos ?? []
            let shape = scan.scanShape(id)
            widthInches = shape?.widthInches ?? 8.5
            editor = PhotoBoxEditor(boxes: boxes, aspect: shape?.aspect ?? 11 / 8.5)
            image = await scan.image(id, asScanned: true)
            focused = true
        }
    }

    /// The scan drawn `fit` points large, taking drags, the pointer and the keys.
    private func glass(_ image: NSImage, _ fit: CGSize) -> some View {
        let width: Double = fit.width
        return PhotoCanvas(image: image, boxes: editor.boxes, selected: editor.selected, focused: focused)
            .frame(width: fit.width, height: fit.height)
            .contentShape(Rectangle())
            .gesture(DragGesture(minimumDistance: 0)
                .onChanged { g in
                    if !editor.isDragging { editor.press(at: point(g.startLocation, width), pageWidth: width) }
                    editor.drag(to: point(g.location, width), snap: NSEvent.modifierFlags.contains(.shift))
                }
                .onEnded { _ in
                    editor.release()
                    focused = true
                    announce()
                })
            .onContinuousHover { phase in
                if case .active(let at) = phase { hover = editor.grip(at: point(at, width), pageWidth: width) }
            }
            .pointerStyle(pointer)
            .focusable()
            .focused($focused)
            .focusEffectDisabled()
            .onKeyPress(phases: [.down, .repeat]) { key(press: $0) }
            .accessibilityLabel("Photos on the glass")
            .accessibilityValue(editor.status(widthInches: widthInches))
            .accessibilityHint("Tab picks a photo. Arrow keys move it, Shift-arrow keys resize it, Option-arrow keys turn it, Delete removes it.")
    }

    private var pointer: PointerStyle {
        switch hover {
        case .rotate: return .link
        case .corner(0): return .frameResize(position: .topLeading)
        case .corner(1): return .frameResize(position: .topTrailing)
        case .corner(2): return .frameResize(position: .bottomTrailing)
        case .corner: return .frameResize(position: .bottomLeading)
        case .move: return editor.isDragging ? .grabActive : .grabIdle
        case .draw, .none: return .rectSelection
        }
    }

    private func key(press: KeyPress) -> KeyPress.Result {
        let shift = press.modifiers.contains(.shift)
        let option = press.modifiers.contains(.option)
        // Shift-Tab arrives as a back tab.
        let backTab = press.characters == "\u{19}"
        if press.key == .tab || backTab {
            guard editor.selectNext(backwards: shift || backTab) else { return .ignored }
            announce()
            return .handled
        }
        if press.key == .delete || press.key == .deleteForward {
            guard editor.selectedBox != nil else { return .ignored }
            change { $0.removeSelected() }
            return .handled
        }
        let step: (dx: Int, dy: Int)
        switch press.key {
        case .leftArrow: step = (-1, 0)
        case .rightArrow: step = (1, 0)
        case .upArrow: step = (0, -1)
        case .downArrow: step = (0, 1)
        default: return .ignored
        }
        guard editor.selectedBox != nil else { return .ignored }
        editor.nudge(dx: step.dx, dy: step.dy, resize: shift && !option, turn: option, coarse: option && shift)
        return .handled
    }

    private func change(_ body: (inout PhotoBoxEditor) -> Void) {
        body(&editor)
        announce()
    }

    private func findAgain() {
        finding = true
        Task {
            if let found = await scan.photosFound(id) {
                editor.replaceAll(found)
                announce(found.count == 1 ? "1 photo found" : "\(found.count) photos found")
            }
            finding = false
        }
    }

    /// VoiceOver says what changed (the Windows app's `Prompt.Announce`).
    private func announce(_ text: String? = nil) {
        let info: [NSAccessibility.NotificationUserInfoKey: Any] = [
            .announcement: text ?? editor.status(widthInches: widthInches),
            .priority: NSAccessibilityPriorityLevel.high.rawValue,
        ]
        NSAccessibility.post(element: NSApp as Any, notification: .announcementRequested, userInfo: info)
    }

    private func point(_ location: CGPoint, _ width: Double) -> PhotoPoint {
        PhotoPoint(Double(location.x) / width, Double(location.y) / width)
    }

    private func fitted(_ size: NSSize, in space: CGSize) -> CGSize {
        guard size.width > 0, size.height > 0 else { return space }
        let scale = min(space.width / size.width, space.height / size.height)
        return CGSize(width: size.width * scale, height: size.height * scale)
    }
}

/// The scan with the glass dimmed outside the photos, each outlined and numbered as it's saved; the selected one with its
/// corner handles and its turning handle (boxes in units of the scan's width, y down).
private struct PhotoCanvas: View {
    let image: NSImage
    let boxes: [PhotoBox]
    let selected: Int
    let focused: Bool

    var body: some View {
        Canvas { ctx, size in
            let width: Double = size.width
            let page = CGRect(origin: .zero, size: size)
            ctx.draw(Image(nsImage: image), in: page)
            ctx.drawLayer { layer in
                layer.fill(Path(page), with: .color(.black.opacity(0.4)))
                layer.blendMode = .clear
                for box in boxes { layer.fill(outline(box, width), with: .color(.black)) }
            }
            for (i, box) in boxes.enumerated() {
                draw(box, number: i + 1, selected: i == selected, width: width, in: &ctx)
            }
        }
        .accessibilityHidden(true)
    }

    private func draw(_ box: PhotoBox, number: Int, selected: Bool, width: Double, in ctx: inout GraphicsContext) {
        let shape = outline(box, width)
        let accent = GraphicsContext.Shading.color(.accentColor)
        ctx.stroke(shape, with: .color(.black.opacity(0.5)), lineWidth: 4)
        ctx.stroke(shape, with: selected ? accent : .color(.white), lineWidth: selected && focused ? 3 : 2)

        // The number, as the photos are saved.
        let centre = CGPoint(x: box.centerX * width, y: box.centerY * width)
        let disc = Path(ellipseIn: CGRect(x: centre.x - 14, y: centre.y - 14, width: 28, height: 28))
        ctx.fill(disc, with: selected ? accent : .color(.black.opacity(0.4)))
        ctx.draw(Text("\(number)").font(.system(size: 15, weight: .semibold)).foregroundStyle(.white), at: centre)
        guard selected else { return }

        let h: Double = PhotoBoxEditor.handle
        let corners: [CGPoint] = box.corners().map { CGPoint(x: $0.x * width, y: $0.y * width) }
        for c in corners {
            let square = Path(CGRect(x: c.x - h / 2, y: c.y - h / 2, width: h, height: h))
            ctx.fill(square, with: .color(.white))
            ctx.stroke(square, with: .color(.black.opacity(0.5)), lineWidth: 1)
        }
        let top = CGPoint(x: (corners[0].x + corners[1].x) / 2, y: (corners[0].y + corners[1].y) / 2)
        let at = PhotoBoxEditor.rotateHandle(box, pageWidth: width)
        let handle = CGPoint(x: at.x * width, y: at.y * width)
        var line = Path()
        line.move(to: top)
        line.addLine(to: handle)
        ctx.stroke(line, with: accent, lineWidth: 2)
        let r: Double = h / 2 + 1
        let dot = Path(ellipseIn: CGRect(x: handle.x - r, y: handle.y - r, width: 2 * r, height: 2 * r))
        ctx.fill(dot, with: .color(.white))
        ctx.stroke(dot, with: accent, lineWidth: 2)
    }

    private func outline(_ box: PhotoBox, _ width: Double) -> Path {
        var p = Path()
        p.addLines(box.corners().map { CGPoint(x: $0.x * width, y: $0.y * width) })
        p.closeSubpath()
        return p
    }
}
