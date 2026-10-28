import AppKit
import PdfCore
import PrintCore
import PrintMac

/// File › Scan… (the Windows app's Scan dialog): scans over eSCL with Inkvolt Print's client (`EsclClient`) from the
/// scanners Bonjour finds on the network (`BonjourDiscovery`, `_uscan` and `_uscans`), or from a USB scanner macOS has a
/// driver for (ImageCaptureCore, `SystemScanners`); source (glass, feeder, both sides), color, resolution and page size
/// from the scanner's capabilities (`ScanChoices`). Pages arrive as JPEGs and become PDF pages as they are (PdfCore's
/// `ImageImport`, at the scan's resolution); Create PDF opens them as a new, unsaved document, and with "Make the text
/// searchable" runs Recognize Text on it (one undo step). Local Network denied is said, with the way to allow it.
@MainActor
final class ScanWindowController: NSWindowController, NSWindowDelegate {
    static var shared: ScanWindowController?
    /// The self-test's scanners (Inkvolt Print's demo ones): no discovery, nothing on the network.
    static var testScanners: [SystemScanner]?
    /// The self-test's recognizer for "Make the text searchable" (nil: Vision's).
    static var testRecognizer: Recognizer?

    /// The self-test scans from Inkvolt Print's demo scanners (a laser with glass and feeder, a photo flatbed).
    static func useDemoScanners() { testScanners = DemoScanDevice.all }

    /// A scanner in the list: its id (what's remembered), its name and how to reach it.
    struct Scanner {
        let id: String
        let name: String
        let device: @MainActor () -> (any ScanDevice)?
    }

    /// A page scanned: its JPEG and the resolution it was scanned at.
    struct Page {
        let jpeg: [UInt8]
        let dpi: Int
    }

    let scannerPopup = NSPopUpButton(frame: .zero, pullsDown: false)
    let sourcePopup = NSPopUpButton(frame: .zero, pullsDown: false)
    let colorPopup = NSPopUpButton(frame: .zero, pullsDown: false)
    let resolutionPopup = NSPopUpButton(frame: .zero, pullsDown: false)
    let sizePopup = NSPopUpButton(frame: .zero, pullsDown: false)
    let ocr = NSButton(checkboxWithTitle: "Make the text searchable (OCR)", target: nil, action: nil)
    let scannerState = NSTextField(wrappingLabelWithString: "")
    let pageCount = NSTextField(labelWithString: "")
    let message = NSTextField(wrappingLabelWithString: "")
    let thumbs = NSStackView()
    let scanButton = NSButton(title: "Scan", target: nil, action: nil)
    let stopButton = NSButton(title: "Stop Scanning", target: nil, action: nil)
    let createButton = NSButton(title: "Create PDF", target: nil, action: nil)
    let removeLastButton = NSButton(title: "Remove Last Page", target: nil, action: nil)
    private let settingsButton = NSButton(title: "Open Local Network Settings", target: nil, action: nil)
    private let progress = NSProgressIndicator()

    private(set) var scanners: [Scanner] = []
    private(set) var pages: [Page] = []
    private(set) var caps: ScannerCapabilities?
    private(set) var isScanning = false
    /// The document Create PDF last opened (the self-test reads it).
    private(set) var lastCreated: PdfDocument?
    private var device: (any ScanDevice)?
    private var connectTask: Task<Void, Never>?
    private(set) var scanTask: Task<Void, Never>?
    private var discovery: BonjourDiscovery?
    private var systemScanners: SystemScanners?
    private let localNetwork = LocalNetworkSignal()
    private var network: [DiscoveredPrinter] = []
    private var usb: [SystemScanner] = []
    private var sources: [ScanSource] = []
    private var colors: [ScanColor] = []
    private var resolutions: [Int] = []
    private var sizes: [ScanPageSize] = []
    private var filling = false

    static func show() {
        let controller = shared ?? ScanWindowController()
        shared = controller
        controller.showWindow(nil)
        controller.window?.makeKeyAndOrderFront(nil)
        controller.startLooking()
    }

    init() {
        let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 600, height: 520), styleMask: [.titled, .closable, .resizable], backing: .buffered, defer: false)
        window.title = "Scan"
        window.isRestorable = false
        window.minSize = NSSize(width: 520, height: 440)
        super.init(window: window)
        window.delegate = self
        for (popup, label) in [(scannerPopup, "Scanner"), (sourcePopup, "Source"), (colorPopup, "Color"), (resolutionPopup, "Resolution"),
                               (sizePopup, "Page size")] {
            popup.target = self
            popup.setAccessibilityLabel(label)
        }
        scannerPopup.action = #selector(scannerChanged)
        sourcePopup.action = #selector(sourceChanged)
        for b in [scanButton, stopButton, createButton, removeLastButton, settingsButton] { b.target = self }
        scanButton.action = #selector(scanClicked)
        stopButton.action = #selector(stopClicked)
        createButton.action = #selector(createClicked)
        removeLastButton.action = #selector(removeLast)
        settingsButton.action = #selector(openSettings)
        scanButton.keyEquivalent = "\r"
        stopButton.isHidden = true
        settingsButton.isHidden = true
        ocr.state = AppSettings.defaults.object(forKey: AppSettings.Key.scanOcr) as? Bool == false ? .off : .on
        scannerState.textColor = .secondaryLabelColor
        scannerState.preferredMaxLayoutWidth = 520
        message.preferredMaxLayoutWidth = 520
        pageCount.font = .systemFont(ofSize: 13, weight: .semibold)
        progress.style = .bar
        progress.isIndeterminate = true
        progress.isHidden = true
        thumbs.spacing = 6
        thumbs.setAccessibilityLabel("Scanned pages")

        let grid = NSGridView(views: [
            [NSTextField(labelWithString: "Scanner:"), scannerPopup],
            [NSTextField(labelWithString: "Source:"), sourcePopup],
            [NSTextField(labelWithString: "Color:"), colorPopup],
            [NSTextField(labelWithString: "Resolution:"), resolutionPopup],
            [NSTextField(labelWithString: "Page size:"), sizePopup],
        ])
        grid.column(at: 0).xPlacement = .trailing
        grid.rowSpacing = 8
        scannerPopup.widthAnchor.constraint(greaterThanOrEqualToConstant: 300).isActive = true
        let thumbScroll = NSScrollView()
        thumbScroll.documentView = thumbs
        thumbScroll.hasHorizontalScroller = true
        thumbScroll.heightAnchor.constraint(equalToConstant: 110).isActive = true
        thumbs.translatesAutoresizingMaskIntoConstraints = false
        thumbs.topAnchor.constraint(equalTo: thumbScroll.contentView.topAnchor).isActive = true
        thumbs.leadingAnchor.constraint(equalTo: thumbScroll.contentView.leadingAnchor).isActive = true
        let pagesRow = NSStackView(views: [pageCount, NSView(), removeLastButton])
        let cancel = NSButton(title: "Cancel", target: self, action: #selector(cancelClicked))
        cancel.keyEquivalent = "\u{1b}"
        let spacer = NSView()
        spacer.setContentHuggingPriority(.init(1), for: .horizontal)
        let buttons = NSStackView(views: [spacer, scanButton, stopButton, createButton, cancel])
        let stack = NSStackView(views: [grid, scannerState, settingsButton, ocr, pagesRow, thumbScroll, message, progress, buttons])
        stack.orientation = .vertical
        stack.alignment = .leading
        stack.spacing = 10
        stack.edgeInsets = NSEdgeInsets(top: 20, left: 20, bottom: 20, right: 20)
        for v in [buttons, pagesRow, thumbScroll, progress] { v.widthAnchor.constraint(equalTo: stack.widthAnchor, constant: -40).isActive = true }
        window.contentView = stack
        window.center()
        refresh()
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError("not used") }

    // MARK: Finding scanners

    /// Starts discovery (once): network scanners through Bonjour, USB ones through ImageCaptureCore.
    func startLooking() {
        if let test = Self.testScanners {
            usb = test
            rebuildList()
            return
        }
        guard discovery == nil else { return }
        scannerState.stringValue = "Looking for scanners…"
        localNetwork.onChange { [weak self] access in
            Task { @MainActor in self?.localNetworkChanged(access) }
        }
        let discovery = BonjourDiscovery(localNetwork: localNetwork) { [weak self] services in
            let found = DiscoveredPrinters.join(services).filter { $0.hasScanner && $0.esclRoot != nil }
            Task { @MainActor in
                self?.network = found
                self?.rebuildList()
            }
        }
        self.discovery = discovery
        discovery.start()
        let system = SystemScanners { [weak self] list in
            self?.usb = list.filter(\.usb)
            self?.rebuildList()
        }
        systemScanners = system
        system.start()
        Task { [weak self] in
            try? await Task.sleep(for: .seconds(8))
            guard let self, self.scanners.isEmpty, self.localNetwork.access != .denied else { return }
            self.scannerState.stringValue = "No scanner found. Turn the scanner on and connect it to this network, or plug it into this Mac with USB."
        }
    }

    private func localNetworkChanged(_ access: LocalNetworkAccess) {
        let denied = access == .denied
        settingsButton.isHidden = !denied
        if denied {
            scannerState.stringValue = "Inkvolt PDF isn't allowed to look for scanners on your network. Allow it in System Settings › Privacy & Security "
                + "› Local Network (USB scanners still work)."
        } else if scanners.isEmpty {
            scannerState.stringValue = "Looking for scanners…"
            discovery?.restart()
        }
    }

    @objc private func openSettings() { NSWorkspace.shared.open(SystemSettings.localNetwork) }

    /// The list from what was found, the remembered (or current) scanner chosen.
    private func rebuildList() {
        let transport = URLSessionTransport.factory(localNetwork: localNetwork)
        var list: [Scanner] = network.compactMap { printer in
            guard let root = printer.esclRoot, let host = printer.host else { return nil }
            return Scanner(id: "escl:" + printer.uuid, name: printer.name) { EsclClient(DeviceHttp(host: host, transport: transport), root: root) }
        }
        let system = systemScanners
        for s in usb {
            let demo = Self.testScanners != nil
            list.append(Scanner(id: "icc:" + s.id, name: s.name + (demo ? "" : " (USB)")) {
                demo ? DemoScanDevice(s) : system?.device(s.id)
            })
        }
        let current = scanners.indices.contains(scannerPopup.indexOfSelectedItem) ? scanners[scannerPopup.indexOfSelectedItem].id : nil
        scanners = list
        scannerPopup.removeAllItems()
        scannerPopup.addItems(withTitles: list.map(\.name))
        if list.isEmpty { return refresh() }
        if localNetwork.access != .denied { scannerState.stringValue = "" }
        let wanted = current ?? AppSettings.defaults.string(forKey: AppSettings.Key.scanDevice)
        let index = list.firstIndex { $0.id == wanted } ?? 0
        scannerPopup.selectItem(at: index)
        if list[index].id != current { connect() }
        refresh()
    }

    // MARK: Choices

    @objc private func scannerChanged() { connect() }

    /// Reads the chosen scanner's capabilities, then fills the choices from them.
    private func connect() {
        connectTask?.cancel()
        caps = nil
        device = nil
        guard scanners.indices.contains(scannerPopup.indexOfSelectedItem) else { return refresh() }
        let scanner = scanners[scannerPopup.indexOfSelectedItem]
        AppSettings.defaults.set(scanner.id, forKey: AppSettings.Key.scanDevice)
        guard let device = scanner.device() else {
            message.stringValue = "\(scanner.name) can't be used now."
            return refresh()
        }
        self.device = device
        message.stringValue = "Connecting to \(scanner.name)…"
        refresh()
        connectTask = Task { [weak self] in
            do {
                let caps = try await device.capabilities()
                guard let self, !Task.isCancelled else { return }
                self.caps = caps
                self.message.stringValue = caps == nil ? "\(scanner.name) didn't say what it can scan; it may not be an eSCL scanner." : ""
                self.fillChoices()
            } catch {
                guard let self, !Task.isCancelled else { return }
                self.message.stringValue = "\(scanner.name) didn't answer: \(Self.describe(error))"
                self.refresh()
            }
        }
    }

    @objc private func sourceChanged() { fillChoices(keepSource: true) }

    /// Source, color, resolution and page size from the capabilities, keeping the current (or remembered) choices.
    private func fillChoices(keepSource: Bool = false) {
        guard let caps else { return refresh() }
        filling = true
        defer { filling = false }
        let d = AppSettings.defaults
        if !keepSource {
            sources = caps.sources
            sourcePopup.removeAllItems()
            sourcePopup.addItems(withTitles: sources.map(ScanChoices.sourceLabel))
            let remembered = d.string(forKey: AppSettings.Key.scanSource)
            sourcePopup.selectItem(at: sources.firstIndex { Self.key($0) == remembered } ?? 0)
        }
        let source = currentSource
        colors = ScanChoices.colors(caps, source)
        colorPopup.removeAllItems()
        colorPopup.addItems(withTitles: colors.map { $0 == .color ? "Color" : "Grayscale" })
        let wantColor = d.object(forKey: AppSettings.Key.scanColor) as? Bool ?? true
        colorPopup.selectItem(at: colors.firstIndex(of: wantColor ? .color : .grayscale) ?? 0)
        resolutions = ScanChoices.resolutions(caps, source)
        resolutionPopup.removeAllItems()
        resolutionPopup.addItems(withTitles: resolutions.map { "\($0) dpi" })
        let dpi = d.object(forKey: AppSettings.Key.scanResolution) as? Int ?? 300
        resolutionPopup.selectItem(at: resolutions.firstIndex(of: dpi) ?? resolutions.firstIndex { $0 >= 300 } ?? max(resolutions.count - 1, 0))
        sizes = ScanChoices.pageSizes(caps, source)
        sizePopup.removeAllItems()
        sizePopup.addItems(withTitles: sizes.map(\.label))
        if !sizes.isEmpty {
            let metric = Locale.current.measurementSystem == .metric
            let size = ScanChoices.defaultPageSize(sizes, remembered: d.string(forKey: AppSettings.Key.scanPageSize), metric: metric)
            sizePopup.selectItem(at: sizes.firstIndex { $0.key == size.key } ?? 0)
        }
        refresh()
    }

    private var currentSource: ScanSource { sources.indices.contains(sourcePopup.indexOfSelectedItem) ? sources[sourcePopup.indexOfSelectedItem] : .platen }

    private static func key(_ source: ScanSource) -> String {
        switch source {
        case .platen: "Platen"
        case .adf: "Feeder"
        case .adfDuplex: "FeederDuplex"
        }
    }

    /// The scan the choices make (and they're remembered, under the Windows names).
    var request: ScanRequest {
        let source = currentSource
        let color = colors.indices.contains(colorPopup.indexOfSelectedItem) ? colors[colorPopup.indexOfSelectedItem] : .color
        let dpi = resolutions.indices.contains(resolutionPopup.indexOfSelectedItem) ? resolutions[resolutionPopup.indexOfSelectedItem] : 300
        let size = sizes.indices.contains(sizePopup.indexOfSelectedItem) ? sizes[sizePopup.indexOfSelectedItem] : nil
        return ScanChoices.request(source, color, dpi, size)
    }

    private func rememberChoices() {
        let d = AppSettings.defaults
        d.set(Self.key(currentSource), forKey: AppSettings.Key.scanSource)
        d.set(request.color == .color, forKey: AppSettings.Key.scanColor)
        d.set(request.resolution, forKey: AppSettings.Key.scanResolution)
        if sizes.indices.contains(sizePopup.indexOfSelectedItem) { d.set(sizes[sizePopup.indexOfSelectedItem].key, forKey: AppSettings.Key.scanPageSize) }
        d.set(ocr.state == .on, forKey: AppSettings.Key.scanOcr)
    }

    // MARK: Scanning

    private func refresh() {
        let ready = caps != nil && device != nil
        scanButton.isEnabled = ready && !isScanning
        scanButton.isHidden = isScanning
        stopButton.isHidden = !isScanning
        createButton.isEnabled = !pages.isEmpty && !isScanning
        removeLastButton.isEnabled = !pages.isEmpty && !isScanning
        for p in [scannerPopup, sourcePopup, colorPopup, resolutionPopup, sizePopup] { p.isEnabled = !isScanning && p.numberOfItems > 0 }
        pageCount.stringValue = pages.isEmpty ? "No pages yet" : (pages.count == 1 ? "1 page" : "\(pages.count) pages")
        progress.isHidden = !isScanning
        if isScanning { progress.startAnimation(nil) } else { progress.stopAnimation(nil) }
    }

    @objc func scanClicked() {
        guard let device, caps != nil, !isScanning else { return NSSound.beep() }
        rememberChoices()
        let request = request
        isScanning = true
        message.stringValue = "Scanning… (the first page takes longer if the scanner was asleep)"
        refresh()
        scanTask = Task { [weak self] in
            var failure: Error?
            do {
                for try await jpeg in device.scan(request) {
                    self?.added(jpeg, dpi: request.resolution)
                }
            } catch {
                failure = error
            }
            self?.scanEnded(failure)
        }
    }

    private func added(_ jpeg: [UInt8], dpi: Int) {
        guard jpeg.count > 4, jpeg[0] == 0xFF, jpeg[1] == 0xD8 else {
            message.stringValue = "The scanner sent a page that can't be read; it was left out."
            return
        }
        pages.append(Page(jpeg: jpeg, dpi: dpi))
        if let image = NSImage(data: Data(jpeg)) {
            let view = NSImageView(image: image)
            view.imageScaling = .scaleProportionallyUpOrDown
            view.widthAnchor.constraint(equalToConstant: 76).isActive = true
            view.heightAnchor.constraint(equalToConstant: 100).isActive = true
            view.setAccessibilityLabel("Page \(pages.count)")
            thumbs.addArrangedSubview(view)
        }
        refresh()
    }

    private func scanEnded(_ error: Error?) {
        isScanning = false
        scanTask = nil
        if let error, !(error is CancellationError) {
            message.stringValue = "The scan stopped: \(Self.describe(error))"
        } else {
            message.stringValue = pages.isEmpty ? "" : "Scan more pages, or Create PDF."
        }
        refresh()
    }

    @objc func stopClicked() {
        message.stringValue = "Stopping the scan…"
        scanTask?.cancel()
    }

    @objc func removeLast() {
        guard !pages.isEmpty else { return }
        pages.removeLast()
        if let last = thumbs.arrangedSubviews.last { thumbs.removeArrangedSubview(last); last.removeFromSuperview() }
        refresh()
    }

    /// Makes the pages a PDF (the JPEGs as they are, each page the size it was scanned at) and opens it as a new document.
    @objc func createClicked() {
        guard !pages.isEmpty, !isScanning else { return NSSound.beep() }
        rememberChoices()
        let images = pages.enumerated().map { (bytes: Self.withDensity($0.element.jpeg, dpi: $0.element.dpi), name: "Scan page \($0.offset + 1).jpg") }
        let count = pages.count
        let searchable = ocr.state == .on
        message.stringValue = "Making the PDF…"
        Task { [weak self] in
            let made = await Task.detached { Result { try ImageImport.imagesToPdf(images) } }.value
            guard let self else { return }
            switch made {
            case .failure(let error):
                self.message.stringValue = "The scan couldn't be made into a PDF: \((error as? PdfEditError)?.message ?? error.localizedDescription)"
            case .success(let bytes):
                guard let document = NewDocuments.open(bytes, name: NewDocuments.name("Scan")) else { return }
                self.lastCreated = document
                self.clearPages()
                self.window?.orderOut(nil)
                guard searchable else { return }
                try? await Task.sleep(for: .milliseconds(400)) // the window shown and fitted
                if let c = document.windowControllers.first as? DocumentWindowController {
                    let recognizer = Self.testRecognizer
                    c.startLongTask { await c.runRecognize(pages: Array(0..<count), recognizer: recognizer) }
                }
            }
        }
    }

    private func clearPages() {
        pages = []
        for v in thumbs.arrangedSubviews { thumbs.removeArrangedSubview(v); v.removeFromSuperview() }
        message.stringValue = ""
        refresh()
    }

    @objc func cancelClicked() {
        if isScanning { scanTask?.cancel() }
        if !pages.isEmpty && !Report.isRunning {
            let alert = NSAlert()
            alert.messageText = pages.count == 1 ? "Discard the scanned page?" : "Discard the \(pages.count) scanned pages?"
            alert.addButton(withTitle: "Discard")
            alert.addButton(withTitle: "Keep Scanning")
            guard alert.runModal() == .alertFirstButtonReturn else { return }
        }
        clearPages()
        window?.orderOut(nil)
    }

    func windowShouldClose(_ sender: NSWindow) -> Bool {
        cancelClicked()
        return false
    }

    private static func describe(_ error: Error) -> String {
        if let e = error as? ScanError { return e.description }
        if LocalNetworkSignal.isDenied(error) { return "Local Network access is off for Inkvolt PDF (System Settings › Privacy & Security › Local Network)." }
        return error.localizedDescription
    }

    /// The JPEG with its JFIF resolution set to the scan's (scanners often leave it unset, and a page would come out at
    /// 96 dpi, three times too big): the APP0 segment's density, or a new APP0 after the start marker.
    static func withDensity(_ jpeg: [UInt8], dpi: Int) -> [UInt8] {
        guard jpeg.count > 4, jpeg[0] == 0xFF, jpeg[1] == 0xD8, dpi > 0, dpi < 65536 else { return jpeg }
        let hi = UInt8(dpi >> 8), lo = UInt8(dpi & 0xFF)
        let jfif: [UInt8] = [0x4A, 0x46, 0x49, 0x46, 0x00]
        if jpeg.count > 18, jpeg[2] == 0xFF, jpeg[3] == 0xE0, Array(jpeg[6..<11]) == jfif {
            var out = jpeg
            out[13] = 1 // dots per inch
            out[14] = hi
            out[15] = lo
            out[16] = hi
            out[17] = lo
            return out
        }
        let app0: [UInt8] = [0xFF, 0xE0, 0x00, 0x10] + jfif + [0x01, 0x01, 0x01, hi, lo, hi, lo, 0x00, 0x00]
        return [0xFF, 0xD8] + app0 + Array(jpeg[2...])
    }
}
