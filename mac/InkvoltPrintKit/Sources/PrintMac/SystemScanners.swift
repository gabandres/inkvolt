import AppKit
import Foundation
import ImageCaptureCore
import PrintCore
import UniformTypeIdentifiers

/// macOS's scanners through ImageCaptureCore (the Windows app's WIA list): USB scanners with a driver, and network ones
/// (which a network printer here scans over eSCL instead). ICC's list flaps while the app browses Bonjour (the probe saw a
/// network scanner added and removed every second), so `onChange` gets it only once it has held still for `settle`.
/// USB needs `com.apple.security.device.usb`. Main thread, as ICC calls its delegates there.
@MainActor
// ICC calls its delegates on the main thread: the conformances are main-actor ones, checked at run time.
public final class SystemScanners: NSObject, @preconcurrency ICDeviceBrowserDelegate {
    public static let settle: Duration = .seconds(2)

    private let browser = ICDeviceBrowser()
    private var devices: [String: ICScannerDevice] = [:]
    /// One driver of each device while it's listed: a device has one delegate, so a second wrapper would take its pages.
    private var drivers: [String: SystemScanDevice] = [:]
    private var pending: Task<Void, Never>?
    private let onChange: @MainActor ([SystemScanner]) -> Void

    /// `network`: network scanners too (checks only; the app scans those over eSCL).
    public init(network: Bool = false, onChange: @escaping @MainActor ([SystemScanner]) -> Void) {
        self.onChange = onChange
        super.init()
        browser.delegate = self
        var mask = ICDeviceTypeMask.scanner.rawValue | ICDeviceLocationTypeMask.local.rawValue
        if network { mask |= ICDeviceLocationTypeMask.bonjour.rawValue }
        browser.browsedDeviceTypeMask = ICDeviceTypeMask(rawValue: mask) ?? .scanner
    }

    public func start() { browser.start() }

    /// The scanners ICC lists after browsing for `wait` (USB devices show within a moment), for a read of every printer
    /// (`status --all`); the browser stops again.
    public static func listOnce(wait: Duration = settle + .seconds(1)) async -> [SystemScanner] {
        let scanners = SystemScanners { _ in }
        scanners.start()
        try? await Task.sleep(for: wait)
        scanners.stop()
        return scanners.list
    }

    /// Every scanner ICC lists, network ones too (for checks: the app scans those over eSCL).
    public var allDevices: [(scanner: SystemScanner, device: SystemScanDevice)] {
        devices.keys.compactMap { id in device(id).map { (Self.scanner(id, devices[id]!), $0) } }
    }

    public func stop() { browser.stop() }

    /// Every session still open is closed now (the app quits): the scanner takes the next one at once.
    public func closeSessions() {
        for driver in drivers.values { driver.closeNow() }
    }

    /// The scanner to scan with (a session is opened when it's first used): the same one while the device is listed.
    public func device(_ id: String) -> SystemScanDevice? {
        if let kept = drivers[id] { return kept }
        guard let d = devices[id] else { return nil }
        let driver = SystemScanDevice(d)
        drivers[id] = driver
        return driver
    }

    public var list: [SystemScanner] {
        devices.map { id, d in Self.scanner(id, d) }
            .sorted { $0.name.localizedCaseInsensitiveCompare($1.name) == .orderedAscending }
    }

    /// What the list says of one device: its name, USB or not, and whether a maker's module drives it (roadmap 4.5).
    private static func scanner(_ id: String, _ d: ICScannerDevice) -> SystemScanner {
        let usb = d.transportType?.contains("USB") == true
        // Its USB ids, for knowing a scanner that needed its driver once it has one (`NeedsDriver.scannerListed`).
        let ids = usb && d.usbVendorID > 0 ? String(format: "%04X:%04X", d.usbVendorID & 0xFFFF, d.usbProductID & 0xFFFF) : nil
        return SystemScanner(id: id, name: d.name ?? "Scanner", usb: usb, makerDriver: DriverReadiness.isMakerModule(d.modulePath), usbId: ids)
    }

    public func deviceBrowser(_ browser: ICDeviceBrowser, didAdd device: ICDevice, moreComing: Bool) {
        guard let scanner = device as? ICScannerDevice, let id = scanner.persistentIDString ?? scanner.name else { return }
        if devices[id] !== scanner { drivers[id] = nil }
        devices[id] = scanner
        changed()
    }

    public func deviceBrowser(_ browser: ICDeviceBrowser, didRemove device: ICDevice, moreGoing: Bool) {
        guard let id = device.persistentIDString ?? device.name else { return }
        devices[id] = nil
        drivers[id] = nil
        changed()
    }

    public func didRemove(_ device: ICDevice) {}

    // MARK: Buttons (roadmap 2.2)

    private var listeners: [Int: (device: String, pressed: @Sendable () -> Void)] = [:]
    private var nextListener = 0

    /// A scanner's button was pressed and this app is the target macOS sends that device's presses to: ImageCaptureCore
    /// says so through the browser while no session is open on the device (with one open, the SDK has no delegate method
    /// left that says it; macOS 15's headers name only this one). It doesn't say which button: every press counts as Scan.
    public func deviceBrowser(_ browser: ICDeviceBrowser, requestsSelect device: ICDevice) {
        guard let id = device.persistentIDString ?? device.name else { return }
        for listener in listeners.values where listener.device == id { listener.pressed() }
    }

    /// Hears `device`'s button presses until the result is called (stops hearing).
    func listen(_ device: String, _ pressed: @escaping @Sendable () -> Void) -> @MainActor @Sendable () -> Void {
        nextListener += 1
        let id = nextListener
        listeners[id] = (device, pressed)
        return { [weak self] in self?.listeners[id] = nil }
    }

    /// The listeners hearing buttons now (the report's check).
    public var buttonListeners: Int { listeners.count }

    private func changed() {
        pending?.cancel()
        pending = Task {
            guard (try? await Task.sleep(for: Self.settle)) != nil else { return }
            onChange(list)
        }
    }
}

/// One ImageCaptureCore scanner as the Scan tab (and a shared scanner) drives it: its flatbed and feeder described as eSCL
/// describes a scanner, and a scan that yields each page as JPEG. The session is opened for each use (reading what it
/// offers, a scan) and closed after it (`ScannerSessionUse`), so the device takes the next one at once; the unit is
/// selected and waited for until it says its size and resolutions before anything is asked of it; what the scanner says
/// is PrintCore's `ImageCaptureJob` (a scan that ends without a page says so; one that says nothing for 3 minutes is
/// given up).
@MainActor
public final class SystemScanDevice: NSObject, ScanDevice, @preconcurrency ICScannerDeviceDelegate {
    private let scanner: ICScannerDevice
    private var opened: OnceResult<String?>?
    private var selected: OnceResult<String?>?
    private var closed: OnceResult<Bool>?
    private var use = ScannerSessionUse()
    private var isOpen = false
    /// A close under way: the next open waits for it (opening while the scanner still closes fails with -9921).
    private var closing: Task<Void, Never>?
    /// The unit selected and seen ready in this session.
    private var readyUnit: ICScannerFunctionalUnitType?
    /// Units the scanner has said it selected in this session (its own first one after the session opens, then ours).
    private var selections = 0
    private var job: ImageCaptureJob?
    private var pages: AsyncThrowingStream<[UInt8], any Error>.Continuation?
    private var watchdog: Task<Void, Never>?
    private var folder: URL?
    /// The most bytes a page file of this scan may hold (`ImageCaptureJob.pageLimit`, from the request's area and dpi).
    private var pageLimit = DeviceHttp.maxScanReplyBytes
    /// The words from the scanner under way, one after another: a page is read off the main actor, and the next word (the
    /// next page, the scan's end) waits for it, so pages keep their order and the end comes after the last.
    private var reading: Task<Void, Never>?
    /// Scans begun on this device: a word read for one scan is dropped once another has begun.
    private var scans = 0
    /// Told each step and each word from ImageCaptureCore, in plain words (the report's `--ica-scan`); nil: nothing traced.
    public var trace: ((String) -> Void)?

    init(_ scanner: ICScannerDevice) {
        self.scanner = scanner
        super.init()
        scanner.delegate = self
    }

    // MARK: ScanDevice

    public func capabilities() async throws -> ScannerCapabilities? {
        try await beginUse()
        do {
            let types = scanner.availableFunctionalUnitTypes.compactMap { ICScannerFunctionalUnitType(rawValue: $0.uintValue) }
            if types.isEmpty { throw ScanError(loc("The scanner offers no glass or feeder.")) }
            var platen: InputCaps?, adf: InputCaps?, duplex = false
            for type in types where type == .flatbed || type == .documentFeeder {
                try await select(type)
                let unit = scanner.selectedFunctionalUnit
                let caps = Self.caps(unit)
                if type == .flatbed { platen = caps } else {
                    adf = caps
                    duplex = (unit as? ICScannerFunctionalUnitDocumentFeeder)?.supportsDuplexScanning ?? false
                }
            }
            await endUse()
            return ScannerCapabilities(makeAndModel: scanner.name, platen: platen, adf: adf, adfDuplex: duplex)
        } catch {
            await endUse()
            throw error
        }
    }

    nonisolated public func scan(_ request: ScanRequest) -> AsyncThrowingStream<[UInt8], any Error> {
        AsyncThrowingStream { continuation in
            let task = Task { @MainActor in
                do {
                    try await self.run(request, continuation)
                } catch {
                    continuation.finish(throwing: error)
                }
            }
            continuation.onTermination = { _ in
                task.cancel()
                Task { @MainActor in self.stopped(continuation) }
            }
        }
    }

    /// The reader stopped (or the scan ended): a scan still running is asked to stop, and its session let go.
    private func stopped(_ continuation: AsyncThrowingStream<[UInt8], any Error>.Continuation) {
        guard job != nil, job?.isOver == false else { return }
        trace?("stopped by the reader")
        scanner.cancelScan()
        act(job?.timedOut().map { _ in .finish(loc("The scan was stopped.")) } ?? [])
    }

    private func run(_ request: ScanRequest, _ continuation: AsyncThrowingStream<[UInt8], any Error>.Continuation) async throws {
        // One scan at a time on a device: a second would take the first one's pages.
        if job != nil { throw ScanError(loc("Someone else is using the scanner. Try again in a moment.")) }
        job = ImageCaptureJob()
        scans += 1
        pageLimit = DeviceHttp.maxScanReplyBytes
        pages = continuation
        do {
            try await beginUse()
        } catch {
            job = nil
            pages = nil
            throw error
        }
        do {
            try await select(request.source == .platen ? .flatbed : .documentFeeder)
            try Task.checkCancellation()
        } catch {
            act([.finish(error is CancellationError ? loc("The scan was stopped.") : (error as? ScanError)?.description ?? Self.words(error))])
            return
        }
        let unit = scanner.selectedFunctionalUnit
        unit.measurementUnit = .inches
        let resolutions = Array(unit.supportedResolutions)
        unit.resolution = resolutions.min { abs($0 - request.resolution) < abs($1 - request.resolution) } ?? request.resolution
        unit.pixelDataType = request.color == .color ? .RGB : .gray
        unit.bitDepth = .depth8Bits
        let size = unit.physicalSize
        // The request's region, its offset kept inside the source (a shared scanner's client may ask for one).
        let area = ScanArea.of(request, sourceWidth: Double(size.width), sourceHeight: Double(size.height))
        unit.scanArea = NSRect(x: area.x, y: area.y, width: area.width, height: area.height)
        pageLimit = ImageCaptureJob.pageLimit(width: area.width, height: area.height, dpi: Double(unit.resolution))
        if let feeder = unit as? ICScannerFunctionalUnitDocumentFeeder {
            feeder.documentType = .typeDefault
            if feeder.supportsDuplexScanning { feeder.duplexScanningEnabled = request.source == .adfDuplex }
        }
        let folder = FileManager.default.temporaryDirectory.appendingPathComponent("system-scan-\(UUID().uuidString)")
        do {
            try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        } catch {
            act([.finish(loc("The scan couldn't start: {0}", error.localizedDescription))])
            return
        }
        scanner.transferMode = .fileBased
        scanner.downloadsDirectory = folder
        scanner.documentName = "page"
        scanner.documentUTI = UTType.jpeg.identifier
        self.folder = folder
        trace?("scan: unit \(unit.type.rawValue), \(unit.resolution) dpi, \(unit.pixelDataType.rawValue)/\(unit.bitDepth.rawValue), area \(unit.scanArea), "
            + "physical \(size), transfer \(scanner.transferMode.rawValue), UTI \(scanner.documentUTI)")
        startWatchdog()
        scanner.requestScan()
    }

    /// Gives the scan up after `ImageCaptureJob.quietLimit` without a page or its end (started again at each page).
    private func startWatchdog() {
        watchdog?.cancel()
        watchdog = Task { [weak self] in
            guard (try? await Task.sleep(for: ImageCaptureJob.quietLimit)) != nil, let self else { return }
            self.trace?("no word from the scanner for \(ImageCaptureJob.quietLimit): given up")
            self.scanner.cancelScan()
            self.act(self.job?.timedOut() ?? [])
        }
    }

    /// Does what the job says: a page handed on, or the scan ended (its reason as the error) and the session let go.
    private func act(_ actions: [ImageCaptureJob.Action]) {
        for action in actions {
            switch action {
            case .yield(let page):
                pages?.yield(page)
                startWatchdog()
            case .finish(let reason):
                watchdog?.cancel()
                watchdog = nil
                if let reason { pages?.finish(throwing: ScanError(reason)) } else { pages?.finish() }
                pages = nil
                job = nil
                if let folder { try? FileManager.default.removeItem(at: folder) }
                folder = nil
                Task { await self.endUse() }
            }
        }
    }

    // MARK: Session

    /// One more use of the session: opened (and its units waited for) for the first.
    private func beginUse() async throws {
        guard use.begin() else { return }
        do {
            try await openSession()
        } catch {
            _ = use.end()
            throw error
        }
    }

    /// One use done: the session is closed after the last.
    private func endUse() async {
        guard use.end() else { return }
        let close = Task { await self.closeSession() }
        closing = close
        await close.value
        if closing == close { closing = nil }
    }

    private func openSession() async throws {
        if let closing { await closing.value }
        if isOpen { return }
        let once = OnceResult<String?>()
        opened = once
        send { s in s.requestOpenSession() }
        let error = await wait(once, seconds: 30, timedOut: Self.noAnswer)
        opened = nil
        if let error {
            // No answer: a session that opens later is closed as it comes (`didOpenSessionWithError`), and one that did is let go.
            if error == Self.noAnswer { send { s in s.requestCloseSession() } }
            throw ScanError(error)
        }
        isOpen = true
        readyUnit = nil
        // The units come once the scanner says it's available, a moment after the session opens; then it says which one
        // it selected itself. Selecting before that is overtaken by it (a network all-in-one's scan then never started).
        for _ in 0..<150 where scanner.availableFunctionalUnitTypes.isEmpty || selections == 0 { try await Task.sleep(for: .milliseconds(100)) }
    }

    /// Closes the session (at most 5 seconds' wait for the scanner to say so).
    private func closeSession() async {
        guard isOpen else { return }
        isOpen = false
        readyUnit = nil
        selections = 0
        let once = OnceResult<Bool>()
        closed = once
        send { s in s.requestCloseSession() }
        let timer = Task {
            try? await Task.sleep(for: .seconds(5))
            once.finish(false)
        }
        _ = await withCheckedContinuation { (c: CheckedContinuation<Bool, Never>) in once.start(c) }
        timer.cancel()
        closed = nil
    }

    /// Asks the scanner from a synchronous closure: in an async function Swift would pick ImageCaptureCore's async
    /// overloads, which answer through their own completion instead of the delegate.
    private func send(_ ask: (ICScannerDevice) -> Void) { ask(scanner) }

    /// Closes the session now without waiting (the app quits).
    public func closeNow() {
        guard isOpen else { return }
        isOpen = false
        if job != nil { scanner.cancelScan() }
        scanner.requestCloseSession()
    }

    /// Selects `type` and waits until it says its size and resolutions: right after a session opens the selected unit is
    /// empty even when it's already the type wanted, and a scan asked of it never ends.
    private func select(_ type: ICScannerFunctionalUnitType) async throws {
        if scanner.selectedFunctionalUnit.type == type, readyUnit == type || Self.ready(scanner.selectedFunctionalUnit) {
            readyUnit = type
            return
        }
        let once = OnceResult<String?>()
        selected = once
        scanner.requestSelect(type)
        let error = await wait(once, seconds: 15, timedOut: loc("The scanner didn't answer. Check that it's on and connected."))
        selected = nil
        if let error { throw ScanError(error) }
        for _ in 0..<50 where !Self.ready(scanner.selectedFunctionalUnit) { try await Task.sleep(for: .milliseconds(100)) }
        let unit = scanner.selectedFunctionalUnit
        guard unit.type == type, Self.ready(unit) else {
            trace?("unit \(type.rawValue) not ready: \(unit.type.rawValue), \(unit.physicalSize), \(unit.supportedResolutions.count) resolutions")
            throw ScanError(loc("The scanner didn't say what its glass or feeder offers. Try again in a moment."))
        }
        readyUnit = type
    }

    private static func ready(_ unit: ICScannerFunctionalUnit) -> Bool {
        unit.measurementUnit = .inches
        return ImageCaptureJob.unitReady(width: Double(unit.physicalSize.width), height: Double(unit.physicalSize.height),
                                         resolutions: unit.supportedResolutions.count)
    }

    /// The scanner's answer (nil: done, else its error in words), or `timedOut` after `seconds`.
    private func wait(_ once: OnceResult<String?>, seconds: Int, timedOut: String) async -> String? {
        let timer = Task {
            try? await Task.sleep(for: .seconds(seconds))
            once.finish(timedOut)
        }
        let result = await withCheckedContinuation { (c: CheckedContinuation<String?, Never>) in once.start(c) }
        timer.cancel()
        return result
    }

    /// A unit as eSCL would describe it: sizes in 1/300 inch, its resolutions, colour and grey.
    static func caps(_ unit: ICScannerFunctionalUnit) -> InputCaps {
        unit.measurementUnit = .inches
        let size = unit.physicalSize
        // The scanner's own size: one that isn't a number (or too big for an Int) is taken as the smallest.
        let w = Int(exactly: (size.width * 300).rounded()) ?? 0, h = Int(exactly: (size.height * 300).rounded()) ?? 0
        return InputCaps(minWidth: 300, maxWidth: max(w, 300), minHeight: 300, maxHeight: max(h, 300), colorModes: ["RGB24", "Grayscale8"],
                         resolutions: Array(unit.supportedResolutions))
    }

    // MARK: ICScannerDeviceDelegate

    public func device(_ device: ICDevice, didOpenSessionWithError error: (any Error)?) {
        trace?("session opened: \(error.map { "\($0)" } ?? "ok")")
        guard let opened else {
            // Opened after we stopped waiting: nobody uses it, and one left open holds the device for minutes.
            if error == nil && !isOpen {
                trace?("late session: closed")
                send { s in s.requestCloseSession() }
            }
            return
        }
        opened.finish(error.map(Self.words))
    }

    public func scannerDevice(_ scanner: ICScannerDevice, didSelect functionalUnit: ICScannerFunctionalUnit, error: (any Error)?) {
        trace?("selected unit \(functionalUnit.type.rawValue): \(error.map { "\($0)" } ?? "ok")")
        selections += 1
        selected?.finish(error.map(Self.words))
    }

    public func scannerDevice(_ scanner: ICScannerDevice, didScanTo url: URL) {
        trace?("page file \(url.lastPathComponent): \((try? url.resourceValues(forKeys: [.fileSizeKey]))?.fileSize.map(String.init) ?? "no size") bytes")
        inTurn { scan in
            let event = await self.readPage(url)
            guard scan == self.scans else { return }
            self.act(self.job?.handle(event) ?? [])
        }
    }

    public func scannerDevice(_ scanner: ICScannerDevice, didCompleteScanWithError error: (any Error)?) {
        let reason = error.map(Self.words)
        trace?("scan complete: \(error.map { "\($0)" } ?? "no error")")
        inTurn { scan in
            // A page the scanner wrote without saying so is still the scan's (listed once the pages it named are read and gone).
            let left = self.folder.flatMap { try? FileManager.default.contentsOfDirectory(atPath: $0.path) } ?? []
            if !left.isEmpty { self.trace?("left in the folder: \(left.prefix(20))") }
            for name in left.sorted().prefix(1000) {
                guard let folder = self.folder else { break }
                let event = await self.readPage(folder.appendingPathComponent(name))
                guard scan == self.scans else { return }
                self.act(self.job?.handle(event) ?? [])
            }
            guard scan == self.scans else { return }
            self.act(self.job?.handle(.completed(reason)) ?? [])
        }
    }

    /// `work` once the words before it are done, given the scan it belongs to (`scans` then): what it does is dropped when
    /// another scan has begun since.
    private func inTurn(_ work: @escaping @MainActor (Int) async -> Void) {
        let before = reading, scan = scans
        reading = Task { @MainActor in
            await before?.value
            await work(scan)
        }
    }

    /// A page file, read off the main actor (up to this scan's `pageLimit`) and deleted.
    private func readPage(_ url: URL) async -> ImageCaptureJob.Event {
        let limit = pageLimit
        return await Task.detached(priority: .userInitiated) { () -> ImageCaptureJob.Event in
            let file = Self.pageFile(url, limit: limit)
            try? FileManager.default.removeItem(at: url)
            switch file {
            case .page(let page): return .page(page)
            case .tooLarge: return .pageTooLarge
            case .unreadable: return .pageUnreadable
            }
        }.value
    }

    public func device(_ device: ICDevice, didCloseSessionWithError error: (any Error)?) {
        trace?("session closed: \(error.map { "\($0)" } ?? "ok")")
        isOpen = false
        readyUnit = nil
        closed?.finish(true)
    }

    public func scannerDevice(_ scanner: ICScannerDevice, didScanTo data: ICScannerBandData) {
        trace?("band: rows \(data.dataStartRow)+\(data.dataNumRows) of \(data.fullImageHeight), \(data.dataSize) bytes")
    }

    public func device(_ device: ICDevice, didEncounterError error: (any Error)?) {
        trace?("device error: \(error.map { "\($0)" } ?? "none")")
    }

    public func device(_ device: ICDevice, didReceiveStatusInformation status: [ICDeviceStatus: Any]) {
        if !status.isEmpty { trace?("status: \(status.map { "\($0.key.rawValue)=\($0.value)" }.sorted())") }
    }

    public func scannerDeviceDidBecomeAvailable(_ scanner: ICScannerDevice) { trace?("scanner available") }

    public func didRemove(_ device: ICDevice) {
        isOpen = false
        readyUnit = nil
        opened?.finish(loc("The scanner was disconnected."))
        selected?.finish(loc("The scanner was disconnected."))
        closed?.finish(true)
        act(job?.handle(.removed) ?? [])
    }

    /// A page file ImageCapture wrote: its bytes, too large, or unreadable.
    enum PageFile: Equatable {
        case page([UInt8])
        case tooLarge
        case unreadable
    }

    /// A page ImageCapture wrote, read only when it is no larger than `limit` (an eSCL page's: `DeviceHttp.maxScanReplyBytes`).
    /// Its pixels are bounded later, as an eSCL page's are (`ScanImaging`).
    nonisolated static func pageFile(_ url: URL, limit: Int = DeviceHttp.maxScanReplyBytes) -> PageFile {
        guard let size = (try? url.resourceValues(forKeys: [.fileSizeKey]))?.fileSize else { return .unreadable }
        if size > limit { return .tooLarge }
        guard let data = try? Data(contentsOf: url) else { return .unreadable }
        if data.count > limit { return .tooLarge }
        return .page([UInt8](data))
    }

    nonisolated static var noAnswer: String { loc("The scanner didn't answer. Check that it's on and connected.") }

    /// The scanner's error in plain words.
    nonisolated static func words(_ error: any Error) -> String {
        // ImageCaptureCore's codes (ICReturnCode); it has none for an empty feeder or a jam: those come in the description.
        switch (error as NSError).code {
        case -9925, -9926: return loc("Someone else is using the scanner. Try again in a moment.")
        case -9923, -9927, -9958: return loc("The scanner didn't answer. Check that it's on and connected.")
        case -9924: return loc("The scan was stopped.")
        default: return loc("The scanner stopped: {0}", (error as NSError).localizedDescription)
        }
    }
}

/// A USB scanner's buttons through ImageCaptureCore (roadmap 2.2's driver half; Windows' WIA button events): presses come
/// through `SystemScanners`' browser, only while this app runs and only when macOS sends the scanner's presses to it.
/// ImageCaptureCore doesn't say which buttons a scanner has, nor which was pressed, so every press is a Scan press and the app
/// offers it for every USB scanner it drives. Not proved on a scanner with buttons (none on the build Mac).
public final class IcaScannerButtons: ScannerButtons {
    private let scanners: SystemScanners

    @MainActor
    public init(_ scanners: SystemScanners) { self.scanners = scanners }

    private final class Watch: ButtonWatch {
        private let claim: WorkClaim<Stopper>

        init(_ claim: WorkClaim<Stopper>) { self.claim = claim }

        func stop() {
            guard let stopper = claim.abandon() else { return }
            Task { @MainActor in stopper.stop() }
        }
    }

    /// The listener's undo, kept for whoever owns the watch (`WorkClaim`: a registration that lands after its watch was
    /// stopped is undone at once, never left hearing presses nobody asked for).
    final class Stopper: Sendable {
        private let undo: @MainActor @Sendable () -> Void

        init(_ undo: @escaping @MainActor @Sendable () -> Void) { self.undo = undo }

        @MainActor func stop() { undo() }
    }

    /// ImageCaptureCore doesn't list a scanner's buttons: every USB scanner is taken to have a Scan button.
    public func buttons(for deviceId: String) -> [String]? { ["scan"] }

    public func watchButtons(_ deviceId: String, _ buttons: [String], pressed: @escaping @Sendable () -> Void) async throws -> any ButtonWatch {
        guard buttons.contains(where: { ScannerButtonNames.name($0) == "scan" }) else { return NoButtons() }
        let claim = WorkClaim<Stopper> { stopper in Task { @MainActor in stopper.stop() } }
        let scanners = self.scanners
        await MainActor.run {
            let undo = scanners.listen(deviceId, pressed)
            _ = claim.deliver(Stopper(undo))
        }
        return Watch(claim)
    }
}
