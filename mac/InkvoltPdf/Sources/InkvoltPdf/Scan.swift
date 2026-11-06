import AppKit
import PdfCore
import PrintCore
import PrintMac

/// File › Scan… (the Windows app's Scan dialog): scans over eSCL with Inkvolt Print's client (`EsclClient`) from the
/// scanners Inkvolt Print remembers (its hand-off in the app group, `SuitePrinters`: listed at once, before Bonjour answers)
/// and those Bonjour finds on the network (`BonjourDiscovery`, `_uscan` and `_uscans`; `ScannerList` joins them, a
/// remembered one found again taking its new address), or from a USB scanner macOS has a driver for (ImageCaptureCore,
/// `SystemScanners`); source (glass, feeder, both sides), color, resolution and page size
/// from the scanner's capabilities (`ScanChoices`). Pages arrive as JPEGs and become PDF pages as they are (PdfCore's
/// `ImageImport`, at the scan's resolution); Create PDF opens them as a new, unsaved document, and with "Make the text
/// searchable" runs Recognize Text on it (one undo step) with its choices: suspect words marked and kept in the text
/// layer, their count said and the Suspect Words pane opened on them. "Leave out blank pages" (on by default) checks each page
/// as it arrives (`ScanRun`, `BlankPage` on a small grey copy) and leaves blank ones out, counted in the message. Presets
/// (Windows' Save as preset…): the source, color, resolution, page size, OCR and blank choices under a name, in the app's
/// settings (`ScanPresets`, Inkvolt Print's built-ins until the list is changed), matched to whichever scanner is chosen
/// (`PresetPlan`: the closest resolution, a size that fits, the source it has), saying what had to give. Local Network
/// denied is said, with the way to allow it.
@MainActor
final class ScanWindowController: NSWindowController, NSWindowDelegate {
    static var shared: ScanWindowController?
    /// The self-test's scanners (Inkvolt Print's demo ones): no discovery, nothing on the network.
    static var testScanners: [SystemScanner]?
    /// The self-test's reader and dictionary for "Make the text searchable" (nil: Vision's, the Mac's).
    static var testReader: (any TextRecognizer)?
    static var testSpelling: (any Spelling)?

    /// The self-test's hand-off from Inkvolt Print (nil: the app group's file).
    static var testRemembered: SuitePrinters?

    /// The self-test scans from Inkvolt Print's demo scanners (a laser with glass and feeder, a photo flatbed).
    static func useDemoScanners() { testScanners = DemoScanDevice.all }

    /// A scanner in the list: its id (what's remembered), its label, its address (a network one's) and how to reach it.
    struct Scanner {
        let id: String
        let name: String
        var host: String?
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
    let skipBlank = NSButton(checkboxWithTitle: "Leave out blank pages", target: nil, action: nil)
    let presetPopup = NSPopUpButton(frame: .zero, pullsDown: false)
    let savePresetButton = NSButton(title: "Save as Preset…", target: nil, action: nil)
    let deletePresetButton = NSButton(title: "Delete Preset", target: nil, action: nil)
    /// The self-test's answer to Save as Preset…'s name (the sheet isn't shown while it runs).
    static var testPresetName: String?
    /// The presets listed after "No preset".
    private(set) var presets: [ScanPreset] = []
    /// A preset chosen before the scanner's capabilities were read: applied once they are.
    private var pendingPreset: ScanPreset?
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

    /// Insert from Scanner: the document the pages go into (nil: Create PDF makes a new one), and where.
    private(set) weak var insertTarget: DocumentWindowController?
    let placePopup = NSPopUpButton(frame: .zero, pullsDown: false)
    private let placeLabel = NSTextField(labelWithString: "Insert:")
    /// The page count and current page of the document when the window opened for it (the places offered).
    private var insertInto: (count: Int, current: Int) = (0, 0)
    /// The pages Insert last put in (the self-test reads it).
    private(set) var lastInserted: (document: PdfDocument, at: Int, count: Int)?

    private(set) var scanners: [Scanner] = []
    private(set) var pages: [Page] = []
    private(set) var caps: ScannerCapabilities?
    private(set) var isScanning = false
    /// The document Create PDF last opened (the self-test reads it).
    private(set) var lastCreated: PdfDocument?
    private var device: (any ScanDevice)?
    private var connectTask: Task<Void, Never>?
    private(set) var scanTask: Task<Void, Never>?
    /// The last job's blank pages left out (the self-test reads it).
    private(set) var lastBlank = 0
    private var discovery: BonjourDiscovery?
    private var systemScanners: SystemScanners?
    private let localNetwork = LocalNetworkSignal()
    private var network: [DiscoveredPrinter] = []
    /// The printers Inkvolt Print remembers, read once (off the main thread) when Scan first looks for scanners.
    private var remembered: SuitePrinters = .empty
    private var usb: [SystemScanner] = []
    private var sources: [ScanSource] = []
    private var colors: [ScanColor] = []
    private var resolutions: [Int] = []
    private var sizes: [ScanPageSize] = []
    private var filling = false

    static func show() {
        let controller = shared ?? ScanWindowController()
        shared = controller
        controller.setTarget(nil)
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
        for (popup, label) in [(scannerPopup, "Scanner"), (presetPopup, "Preset"), (sourcePopup, "Source"), (colorPopup, "Color"),
                               (resolutionPopup, "Resolution"), (sizePopup, "Page size")] {
            popup.target = self
            popup.setAccessibilityLabel(label)
        }
        scannerPopup.action = #selector(scannerChanged)
        sourcePopup.action = #selector(sourceChanged)
        presetPopup.action = #selector(presetChanged)
        savePresetButton.target = self
        savePresetButton.action = #selector(savePresetClicked)
        savePresetButton.toolTip = "Saves the source, color, resolution, page size, OCR and blank page choices under a name, for any scanner."
        deletePresetButton.target = self
        deletePresetButton.action = #selector(deletePresetClicked)
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
        skipBlank.state = AppSettings.defaults.object(forKey: AppSettings.Key.scanSkipBlank) as? Bool == false ? .off : .on
        skipBlank.toolTip = "Pages with almost no ink (the empty back of a one-sided sheet) aren't added. A page with as little as a short word is kept."
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
            [NSTextField(labelWithString: "Preset:"), NSStackView(views: [presetPopup, savePresetButton, deletePresetButton])],
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
        let placeRow = NSStackView(views: [placeLabel, placePopup])
        placePopup.isHidden = true
        placeLabel.isHidden = true
        let stack = NSStackView(views: [grid, scannerState, settingsButton, ocr, skipBlank, placeRow, pagesRow, thumbScroll, message, progress, buttons])
        stack.orientation = .vertical
        stack.alignment = .leading
        stack.spacing = 10
        stack.edgeInsets = NSEdgeInsets(top: 20, left: 20, bottom: 20, right: 20)
        for v in [buttons, pagesRow, thumbScroll, progress] { v.widthAnchor.constraint(equalTo: stack.widthAnchor, constant: -40).isActive = true }
        window.contentView = stack
        window.center()
        fillPresets(select: nil)
        refresh()
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError("not used") }

    /// Pages › Insert from Scanner… (Windows' Organize › Insert from Scanner): the same window, its pages inserted into
    /// `controller`'s document (one undo step) where chosen, instead of a new PDF.
    static func showInsert(into controller: DocumentWindowController) {
        let scan = shared ?? ScanWindowController()
        shared = scan
        scan.setTarget(controller)
        scan.showWindow(nil)
        scan.window?.makeKeyAndOrderFront(nil)
        scan.startLooking()
    }

    /// Scan (nil) or Insert from Scanner into `controller`: the title, the button and the place to insert.
    private func setTarget(_ controller: DocumentWindowController?) {
        guard pages.isEmpty || controller === insertTarget else { return } // pages scanned for one stay for it
        insertTarget = controller
        let count = controller?.engine.pageCount ?? 0, current = controller?.pages.currentPage ?? 0
        insertInto = (count, current)
        window?.title = controller == nil ? "Scan" : "Insert from Scanner"
        createButton.title = controller == nil ? "Create PDF" : "Insert Pages"
        placePopup.removeAllItems()
        placePopup.addItems(withTitles: ["After page \(current + 1)", "Before page \(current + 1)", "At the start", "At the end"])
        placePopup.setAccessibilityLabel("Insert")
        placePopup.isHidden = controller == nil
        placeLabel.isHidden = controller == nil
    }

    // MARK: Finding scanners

    /// Starts discovery (once): network scanners through Bonjour, USB ones through ImageCaptureCore.
    func startLooking() {
        if let test = Self.testScanners {
            usb = test
            remembered = Self.testRemembered ?? .empty
            rebuildList()
            return
        }
        guard discovery == nil else { return }
        scannerState.stringValue = "Looking for scanners…"
        let root = ProKeyRoot.url?.path
        Task { [weak self] in
            let handed = await Task.detached { root.map { SuitePrinters.load(root: $0) } ?? .empty }.value
            guard let self, !handed.printers.isEmpty else { return }
            self.remembered = handed
            self.rebuildList()
        }
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
        var list: [Scanner] = ScannerList.network(remembered: remembered, found: network).map { s in
            Scanner(id: s.key, name: ScannerList.label(s), host: s.host) { EsclClient(DeviceHttp(host: s.host, transport: transport), root: s.esclRoot) }
        }
        let system = systemScanners
        for s in usb {
            let demo = Self.testScanners != nil
            list.append(Scanner(id: "icc:" + s.id, name: demo ? s.name : ScannerList.usbLabel(s.name)) {
                demo ? DemoScanDevice(s) : system?.device(s.id)
            })
        }
        let selected = scanners.indices.contains(scannerPopup.indexOfSelectedItem) ? scanners[scannerPopup.indexOfSelectedItem] : nil
        let current = selected?.id
        scanners = list
        scannerPopup.removeAllItems()
        scannerPopup.addItems(withTitles: list.map(\.name))
        if list.isEmpty { return refresh() }
        if localNetwork.access != .denied { scannerState.stringValue = "" }
        let wanted = current ?? AppSettings.defaults.string(forKey: AppSettings.Key.scanDevice)
        let index = list.firstIndex { $0.id == wanted } ?? 0
        scannerPopup.selectItem(at: index)
        // Another scanner, or the same one at a new address while the old one hasn't answered (DHCP may have moved it).
        let moved = list[index].id == current && list[index].host != selected?.host && caps == nil && !isScanning
        if list[index].id != current || moved { connect() }
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
                if caps != nil, let preset = self.pendingPreset ?? self.selectedPreset { self.applyPreset(preset) }
            } catch {
                guard let self, !Task.isCancelled else { return }
                self.message.stringValue = "\(scanner.name) didn't answer: \(Self.describe(error))"
                self.refresh()
            }
        }
    }

    @objc private func sourceChanged() { fillChoices(keepSource: true) }

    /// Source, color, resolution and page size from the capabilities, keeping the current (or remembered) choices, or
    /// taking `wanted`'s (a preset's plan) and the size `sizeKey`.
    private func fillChoices(keepSource: Bool = false, wanted: ScanRequest? = nil, sizeKey: String? = nil) {
        guard let caps else { return refresh() }
        filling = true
        defer { filling = false }
        let d = AppSettings.defaults
        if !keepSource {
            sources = caps.sources
            sourcePopup.removeAllItems()
            sourcePopup.addItems(withTitles: sources.map(ScanChoices.sourceLabel))
            let remembered = d.string(forKey: AppSettings.Key.scanSource)
            let asked = wanted.flatMap { w in sources.firstIndex(of: w.source) }
            sourcePopup.selectItem(at: asked ?? sources.firstIndex { Self.key($0) == remembered } ?? 0)
        }
        let source = currentSource
        colors = ScanChoices.colors(caps, source)
        colorPopup.removeAllItems()
        colorPopup.addItems(withTitles: colors.map { $0 == .color ? "Color" : "Grayscale" })
        let wantColor = wanted.map { $0.color == .color } ?? d.object(forKey: AppSettings.Key.scanColor) as? Bool ?? true
        colorPopup.selectItem(at: colors.firstIndex(of: wantColor ? .color : .grayscale) ?? 0)
        resolutions = ScanChoices.resolutions(caps, source)
        resolutionPopup.removeAllItems()
        resolutionPopup.addItems(withTitles: resolutions.map { "\($0) dpi" })
        let dpi = wanted?.resolution ?? d.object(forKey: AppSettings.Key.scanResolution) as? Int ?? 300
        let closest = resolutions.indices.min { abs(resolutions[$0] - dpi) < abs(resolutions[$1] - dpi) }
        let fallback = wanted == nil ? resolutions.firstIndex { $0 >= 300 } : closest
        resolutionPopup.selectItem(at: resolutions.firstIndex(of: dpi) ?? fallback ?? max(resolutions.count - 1, 0))
        sizes = ScanChoices.pageSizes(caps, source)
        sizePopup.removeAllItems()
        sizePopup.addItems(withTitles: sizes.map(\.label))
        if !sizes.isEmpty {
            let metric = Locale.current.measurementSystem == .metric
            let remembered = wanted == nil ? d.string(forKey: AppSettings.Key.scanPageSize) : sizeKey
            let size = ScanChoices.defaultPageSize(sizes, remembered: remembered, metric: metric)
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
        d.set(skipBlank.state == .on, forKey: AppSettings.Key.scanSkipBlank)
    }

    // MARK: Presets

    /// The saved presets, as Windows keeps them in its settings (Inkvolt Print's built-ins until the list is changed).
    private static func loadPresets() -> [ScanPreset] {
        let data = AppSettings.defaults.data(forKey: AppSettings.Key.scanPresets)
        return ScanPresets.normalize(data.flatMap { try? JSONDecoder().decode(ScanPresetSettings.self, from: $0) })
    }

    private static func savePresets(_ list: [ScanPreset]) {
        guard let data = try? JSONEncoder().encode(ScanPresetSettings(items: list)) else { return }
        AppSettings.defaults.set(data, forKey: AppSettings.Key.scanPresets)
    }

    /// "No preset", then the saved presets; `id` chosen (without applying it).
    private func fillPresets(select id: String?) {
        presets = Self.loadPresets()
        filling = true
        defer { filling = false }
        presetPopup.removeAllItems()
        // Through the menu: addItems(withTitles:) would drop a preset that happened to be called "No preset".
        for title in ["No preset"] + presets.map(\.name) { presetPopup.menu?.addItem(NSMenuItem(title: title, action: nil, keyEquivalent: "")) }
        presetPopup.selectItem(at: presets.firstIndex { $0.id == id }.map { $0 + 1 } ?? 0)
    }

    var selectedPreset: ScanPreset? {
        let i = presetPopup.indexOfSelectedItem - 1
        return presets.indices.contains(i) ? presets[i] : nil
    }

    @objc private func presetChanged() {
        guard !filling, let preset = selectedPreset else { return refresh() }
        applyPreset(preset)
    }

    /// Sets the choices from a preset matched to this scanner, saying what had to give; waits for the scanner's
    /// capabilities when they aren't read yet.
    private func applyPreset(_ preset: ScanPreset) {
        guard let caps else {
            pendingPreset = preset
            return
        }
        pendingPreset = nil
        let metric = Locale.current.measurementSystem == .metric
        let plan = PresetPlan.plan(preset, caps, feederLoaded: nil, ocrAvailable: true, metric: metric)
        let r = plan.request
        let size = ScanChoices.pageSizes.first { $0.width == r.width && $0.height == r.height }
        fillChoices(wanted: r, sizeKey: size?.key)
        ocr.state = plan.ocr ? .on : .off
        skipBlank.state = preset.skipBlank ? .on : .off
        message.stringValue = plan.notes.isEmpty ? "Preset \"\(preset.name)\" chosen." : plan.notes.joined(separator: " ")
        refresh()
    }

    /// Saves the current choices as a named preset (any scanner can use it), the name asked in a sheet.
    @objc func savePresetClicked() {
        guard caps != nil, !isScanning else { return NSSound.beep() }
        let list = Self.loadPresets()
        let suggested = ScanPresets.uniqueName(list.map(\.name), "My scan")
        if Report.skipsDialogs { return savePreset(named: Self.testPresetName ?? suggested, list) }
        guard let window else { return }
        Task { [weak self] in
            guard let name = await Self.askName(suggested, list, window) else { return }
            self?.savePreset(named: name, list)
        }
    }

    private static func askName(_ suggested: String, _ list: [ScanPreset], _ window: NSWindow) async -> String? {
        let field = NSTextField(string: suggested)
        field.setAccessibilityLabel("Name")
        field.widthAnchor.constraint(equalToConstant: 300).isActive = true
        let problem = NSTextField(wrappingLabelWithString: "")
        problem.textColor = .systemRed
        problem.preferredMaxLayoutWidth = 300
        problem.isHidden = true
        let stack = NSStackView(views: [field, problem])
        stack.orientation = .vertical
        stack.alignment = .leading
        stack.spacing = 6
        while true {
            let alert = NSAlert()
            alert.messageText = "Save as Preset"
            alert.informativeText = "Saves the source, color, resolution, page size, text recognition and blank page choices. "
                + "A preset works with any scanner: what one can't do is matched as closely as it allows."
            alert.addButton(withTitle: "Save")
            alert.addButton(withTitle: "Cancel")
            stack.layoutSubtreeIfNeeded()
            stack.frame.size = stack.fittingSize
            alert.accessoryView = stack
            alert.window.initialFirstResponder = field
            guard await alert.beginSheetModal(for: window) == .alertFirstButtonReturn else { return nil }
            if let wrong = ScanPresets.nameProblem(list, "", field.stringValue) {
                problem.stringValue = wrong // asked again, saying what's wrong
                problem.isHidden = false
                continue
            }
            return field.stringValue
        }
    }

    private func savePreset(named name: String, _ list: [ScanPreset]) {
        if let wrong = ScanPresets.nameProblem(list, "", name) {
            message.stringValue = wrong
            return
        }
        let r = request
        let size = sizes.indices.contains(sizePopup.indexOfSelectedItem) ? sizes[sizePopup.indexOfSelectedItem].key : nil
        let preset = ScanPresets.fromChoices(list, name: name, source: r.source, color: r.color, dpi: r.resolution, pageSize: size,
                                             ocr: ocr.state == .on, skipBlank: skipBlank.state == .on)
        Self.savePresets(list + [preset])
        fillPresets(select: preset.id)
        message.stringValue = "Saved the preset \"\(preset.name)\"."
        refresh()
    }

    @objc func deletePresetClicked() {
        guard !isScanning, let preset = selectedPreset else { return NSSound.beep() }
        if Report.skipsDialogs { return deletePreset(preset) }
        guard let window else { return }
        let alert = NSAlert()
        alert.messageText = "Delete the preset \"\(preset.name)\"?"
        alert.informativeText = "Its choices are forgotten; pages already scanned stay."
        alert.addButton(withTitle: "Delete").hasDestructiveAction = true
        alert.addButton(withTitle: "Cancel")
        Task { [weak self] in
            guard await alert.beginSheetModal(for: window) == .alertFirstButtonReturn else { return }
            self?.deletePreset(preset)
        }
    }

    private func deletePreset(_ preset: ScanPreset) {
        Self.savePresets(Self.loadPresets().filter { $0.id != preset.id })
        fillPresets(select: nil)
        message.stringValue = "Deleted the preset \"\(preset.name)\"."
        refresh()
    }

    // MARK: Scanning

    private func refresh() {
        let ready = caps != nil && device != nil
        scanButton.isEnabled = ready && !isScanning
        scanButton.title = pages.isEmpty ? "Scan" : currentSource == .platen ? "Scan Another Page" : "Scan More Pages"
        skipBlank.isEnabled = !isScanning
        scanButton.isHidden = isScanning
        stopButton.isHidden = !isScanning
        createButton.isEnabled = !pages.isEmpty && !isScanning
        removeLastButton.isEnabled = !pages.isEmpty && !isScanning
        for p in [scannerPopup, presetPopup, sourcePopup, colorPopup, resolutionPopup, sizePopup] { p.isEnabled = !isScanning && p.numberOfItems > 0 }
        savePresetButton.isEnabled = ready && !isScanning
        deletePresetButton.isEnabled = !isScanning && selectedPreset != nil
        pageCount.stringValue = pages.isEmpty ? "No pages yet" : (pages.count == 1 ? "1 page" : "\(pages.count) pages")
        progress.isHidden = !isScanning
        if isScanning { progress.startAnimation(nil) } else { progress.stopAnimation(nil) }
    }

    @objc func scanClicked() {
        guard let device, caps != nil, !isScanning else { return NSSound.beep() }
        rememberChoices()
        let request = request
        let glass = request.source == .platen
        let analysis: ScanRun.Analysis? = skipBlank.state == .on ? { @Sendable jpeg in try ScanImaging.analysis(jpeg) } : nil
        isScanning = true
        message.stringValue = "Scanning… (the first page takes longer if the scanner was asleep)"
        refresh()
        scanTask = Task { [weak self] in
            var (kept, blank, unreadable) = (0, 0, 0)
            var failure: Error?
            do {
                for try await page in ScanRun.pages(device, request, analysis: analysis) {
                    guard let self else { break }
                    switch page.fate {
                    case .blank: blank += 1
                    case .unreadable: unreadable += 1
                    case .kept:
                        kept += 1
                        self.added(page.jpeg, dpi: request.resolution)
                    }
                    self.message.stringValue = ScanRun.progressText(self.pages.count, blank: blank)
                }
            } catch {
                failure = error
            }
            let stopped = Task.isCancelled || failure is CancellationError
            self?.scanEnded(stopped ? nil : failure, stopped: stopped, kept: kept, blank: blank, unreadable: unreadable, glass: glass)
        }
    }

    private func added(_ jpeg: [UInt8], dpi: Int) {
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

    private func scanEnded(_ error: Error?, stopped: Bool, kept: Int, blank: Int, unreadable: Int, glass: Bool) {
        isScanning = false
        scanTask = nil
        lastBlank = blank
        if let error {
            message.stringValue = kept == 0 ? "The scan stopped: \(Self.describe(error))"
                : "The scan stopped after \(ScanRun.pages(kept)), which are kept: \(Self.describe(error))"
        } else if stopped {
            message.stringValue = kept == 0 ? "Scanning stopped." : "Scanning stopped; the \(ScanRun.pages(kept)) scanned are kept."
        } else {
            message.stringValue = ScanRun.doneText(kept: kept, blank: blank, unreadable: unreadable, glass: glass, finish: createButton.title)
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
        let target = insertTarget
        let place = placePopup.indexOfSelectedItem
        Task { [weak self] in
            let made = await Task.detached { Result { try ImageImport.imagesToPdf(images) } }.value
            guard let self else { return }
            switch made {
            case .failure(let error):
                self.message.stringValue = "The scan couldn't be made into a PDF: \((error as? PdfEditError)?.message ?? error.localizedDescription)"
            case .success(let bytes) where target != nil:
                guard let c = target, c.pdf.session != nil else {
                    self.message.stringValue = "The document to insert into has closed."
                    return
                }
                // Where, from the document as it is now (it may have changed meanwhile), as Windows clamps it.
                let n = c.engine.pageCount, current = min(self.insertInto.current, max(n - 1, 0))
                let at = min(max([current + 1, current, 0, n][max(place, 0)], 0), n)
                let label = "Insert \(count == 1 ? "1 page" : "\(count) pages") from the scanner"
                guard await c.insertPages(PdfSource(bytes, nil, NewDocuments.name("Scan")), at: at, pages: nil, label: label) else {
                    self.message.stringValue = "The pages couldn't be inserted."
                    return
                }
                self.lastInserted = (c.pdf, at, count)
                self.clearPages()
                self.window?.orderOut(nil)
                guard searchable else { return }
                let (reader, spelling) = (Self.testReader, Self.testSpelling)
                c.startLongTask { await c.runRecognize(pages: Array(at..<(at + count)), ocr: reader, spelling: spelling) }
            case .success(let bytes):
                guard let document = NewDocuments.open(bytes, name: NewDocuments.name("Scan")) else { return }
                self.lastCreated = document
                self.clearPages()
                self.window?.orderOut(nil)
                guard searchable else { return }
                try? await Task.sleep(for: .milliseconds(400)) // the window shown and fitted
                if let c = document.windowControllers.first as? DocumentWindowController {
                    let (reader, spelling) = (Self.testReader, Self.testSpelling)
                    c.startLongTask { await c.runRecognize(pages: Array(0..<count), ocr: reader, spelling: spelling) }
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
