import AppKit
import PdfCore
import WebKit

/// Web pages to PDF with the WebKit macOS provides (Windows: WebView2): the page loads in a WKWebView in a window that is
/// never shown, with a data store of its own that nothing outlives, then prints itself with the chosen paper, margins and
/// backgrounds. Pop-ups, downloads, permission requests, script dialogs and logins are refused, and WebKit's check of
/// addresses against an online list of bad sites is off; what the page may do is `WebCaptureRules`. Runs on the main
/// thread (WebKit needs it); the page itself runs in WebKit's own sandboxed processes, which end with the view.
@MainActor
final class WebCapture: NSObject, WKNavigationDelegate, WKUIDelegate {
    /// The time limits (the self-test shortens them).
    struct Limits {
        var load = WebCaptureRules.loadTimeout, script = WebCaptureRules.scriptTimeout, print = WebCaptureRules.printTimeout
    }

    private let rules: WebCaptureRules
    private let options: WebPdfOptions
    private let cancel: CancelToken
    private let limits: Limits
    private let web: WKWebView
    private let window: NSWindow
    private var loading: Wait<Void>?
    private var printing: Wait<Bool>?
    /// Why a load this class stopped itself failed (WebKit then reports only an interruption).
    private var refusal: String?

    /// What a capture is made with: nothing kept, nothing asked, nothing looked up (the self-test reads it).
    static func configuration(_ rules: WebCaptureRules, _ options: WebPdfOptions) -> WKWebViewConfiguration {
        let config = WKWebViewConfiguration()
        config.websiteDataStore = .nonPersistent() // no cookies, cache or storage from or for any other document
        config.defaultWebpagePreferences.allowsContentJavaScript = rules.runsPageScripts
        config.preferences.javaScriptCanOpenWindowsAutomatically = false
        config.preferences.isFraudulentWebsiteWarningEnabled = false // it asks an online list about each address
        config.preferences.isElementFullscreenEnabled = false
        config.preferences.shouldPrintBackgrounds = options.backgrounds
        config.preferences.inactiveSchedulingPolicy = .none // a window never shown still loads and lays out the page
        config.mediaTypesRequiringUserActionForPlayback = .all
        config.allowsAirPlayForMediaPlayback = false
        return config
    }

    private init(source: URL, options: WebPdfOptions, cancel: CancelToken, limits: Limits) {
        rules = WebCaptureRules(source: source)
        self.options = options
        self.cancel = cancel
        self.limits = limits
        let frame = NSRect(x: 0, y: 0, width: 1280, height: 900)
        web = WKWebView(frame: frame, configuration: Self.configuration(rules, options))
        window = NSWindow(contentRect: frame, styleMask: [.borderless], backing: .buffered, defer: false)
        window.isReleasedWhenClosed = false
        window.isRestorable = false
        window.contentView = web
        super.init()
        web.navigationDelegate = self
        web.uiDelegate = self
    }

    /// Loads `source` (a web address or a local file) and prints it to PDF bytes.
    /// - Throws: `PdfEditError` (the message says why), `CancellationError`.
    static func print(_ source: URL, options: WebPdfOptions, status: ((String) -> Void)? = nil, cancel: CancelToken, limits: Limits = Limits()) async throws -> [UInt8] {
        try cancel.check()
        let capture = WebCapture(source: source, options: options, cancel: cancel, limits: limits)
        defer { capture.tearDown() }
        return try await capture.run(status)
    }

    private func run(_ status: ((String) -> Void)?) async throws -> [UInt8] {
        status?(rules.loadingText)
        try await load()
        status?("Waiting for the page to settle…")
        try await settle()
        status?("Making the PDF…")
        let folder: URL
        do {
            folder = try ConversionTemp.make(ConversionTemp.webPrefix)
        } catch {
            throw PdfEditError(WebCaptureRules.notPrinted)
        }
        defer { ConversionTemp.remove(folder) }
        let output = folder.appendingPathComponent("page.pdf")
        try await printPage(to: output)
        guard let data = try? Data(contentsOf: output), data.starts(with: Array("%PDF-".utf8)) else { throw PdfEditError(WebCaptureRules.notPrinted) }
        try cancel.check()
        let pdf = [UInt8](data)
        guard let marks = options.headerFooter(title: web.title ?? "", address: web.url?.absoluteString ?? rules.source.absoluteString) else { return pdf }
        return try await Task.detached {
            let engine = try PdfEngine.open(pdf)
            let pages = Array(0..<engine.pageCount)
            engine.close()
            return try HeaderFooter.apply(pdf, nil, pages, marks)
        }.value
    }

    private func load() async throws {
        let wait = Wait<Void>(limit: limits.load, late: WebCaptureRules.lateLoad(limits.load), cancel: cancel)
        loading = wait
        defer { loading = nil }
        try await wait.value {
            if rules.isLocal {
                // The folder: a saved page's pictures sit beside it. Without scripts a page can show those, not read them.
                web.loadFileURL(rules.source, allowingReadAccessTo: rules.source.deletingLastPathComponent())
            } else {
                web.load(URLRequest(url: rules.source, cachePolicy: .reloadIgnoringLocalAndRemoteCacheData, timeoutInterval: limits.load))
            }
        }
    }

    /// Lets late content arrive: waits for the document to be complete, then scrolls to the end and back so pictures that
    /// load as they come into view are fetched. These scripts run apart from the page's (also where it may run none).
    /// A page whose own scripts never let go (a busy loop) never answers: every call has a time limit and Cancel.
    private func settle() async throws {
        for _ in 0..<30 where try await script("document.readyState") != "complete" {
            try await pause(0.25)
        }
        _ = try await script("window.scrollTo(0, document.documentElement.scrollHeight); 'ok'")
        try await pause(0.7)
        _ = try await script("window.scrollTo(0, 0); 'ok'")
        try await pause(0.5)
    }

    private func pause(_ seconds: Double) async throws {
        try cancel.check()
        try await Task.sleep(for: .seconds(seconds))
        try cancel.check()
    }

    private func script(_ js: String) async throws -> String {
        let wait = Wait<String>(limit: limits.script, late: WebCaptureRules.busy, cancel: cancel)
        return try await wait.value { finish in
            web.evaluateJavaScript(js, in: nil, in: .defaultClient) { result in
                switch result {
                case .success(let value): finish(.success(value as? String ?? ""))
                case .failure: finish(.failure(PdfEditError(WebCaptureRules.busy)))
                }
            }
        }
    }

    private func printPage(to output: URL) async throws {
        let (width, height) = options.pageInches
        let margin = options.marginInches * 72
        let info = NSPrintInfo()
        info.paperSize = NSSize(width: width * 72, height: height * 72)
        (info.topMargin, info.bottomMargin, info.leftMargin, info.rightMargin) = (margin, margin, margin, margin)
        info.horizontalPagination = .automatic
        info.verticalPagination = .automatic
        info.isHorizontallyCentered = false
        info.isVerticallyCentered = false
        info.scalingFactor = 1
        info.jobDisposition = .save
        info.dictionary()[NSPrintInfo.AttributeKey.jobSavingURL] = output
        let operation = web.printOperation(with: info)
        operation.showsPrintPanel = false
        operation.showsProgressPanel = false
        operation.view?.frame = NSRect(x: 0, y: 0, width: width * 72, height: height * 72)
        let wait = Wait<Bool>(limit: limits.print, late: WebCaptureRules.latePrint(limits.print), cancel: cancel)
        printing = wait
        defer { printing = nil }
        let printed = try await wait.value {
            operation.runModal(for: window, delegate: self, didRun: #selector(printDidRun(_:success:contextInfo:)), contextInfo: nil)
        }
        if !printed { throw PdfEditError(WebCaptureRules.notPrinted) }
    }

    @objc private func printDidRun(_ operation: NSPrintOperation, success: Bool, contextInfo: UnsafeMutableRawPointer?) {
        printing?.finish(.success(success))
    }

    /// Stops whatever the page still does; WebKit's processes for it end with the view.
    private func tearDown() {
        web.stopLoading()
        web.navigationDelegate = nil
        web.uiDelegate = nil
        window.contentView = nil
        window.close()
    }

    // MARK: Where the page may go

    func webView(_ webView: WKWebView, decidePolicyFor navigationAction: WKNavigationAction, preferences: WKWebpagePreferences) async -> (WKNavigationActionPolicy, WKWebpagePreferences) {
        preferences.allowsContentJavaScript = rules.runsPageScripts
        let mainFrame = navigationAction.targetFrame?.isMainFrame ?? false
        guard navigationAction.targetFrame != nil, !navigationAction.shouldPerformDownload,
              rules.allowsNavigation(to: navigationAction.request.url, mainFrame: mainFrame) else {
            if mainFrame, loading != nil { refuse(WebCaptureRules.notAPage) }
            return (.cancel, preferences)
        }
        return (.allow, preferences)
    }

    func webView(_ webView: WKWebView, decidePolicyFor navigationResponse: WKNavigationResponse) async -> WKNavigationResponsePolicy {
        guard navigationResponse.isForMainFrame else { return navigationResponse.canShowMIMEType ? .allow : .cancel }
        if let http = navigationResponse.response as? HTTPURLResponse, http.statusCode >= 400 {
            refuse(WebCaptureRules.describe(httpStatus: http.statusCode))
            return .cancel
        }
        guard navigationResponse.canShowMIMEType else {
            refuse(WebCaptureRules.notAPage)
            return .cancel
        }
        return .allow
    }

    private func refuse(_ why: String) {
        refusal = why
        loading?.finish(.failure(PdfEditError(why)))
    }

    func webView(_ webView: WKWebView, didFinish navigation: WKNavigation!) {
        loading?.finish(.success(()))
    }

    func webView(_ webView: WKWebView, didFail navigation: WKNavigation!, withError error: Error) {
        failed(error)
    }

    func webView(_ webView: WKWebView, didFailProvisionalNavigation navigation: WKNavigation!, withError error: Error) {
        failed(error)
    }

    private func failed(_ error: Error) {
        let e = error as NSError
        if WebCaptureRules.isInterruption(domain: e.domain, code: e.code) { return } // the page moved on; the load goes on, or its own reason was said
        loading?.finish(.failure(PdfEditError(refusal ?? WebCaptureRules.describe(domain: e.domain, code: e.code))))
    }

    /// The page's process died (a crafted page, or out of memory).
    func webViewWebContentProcessDidTerminate(_ webView: WKWebView) {
        let why = PdfEditError(WebCaptureRules.notAPage)
        loading?.finish(.failure(why))
        printing?.finish(.failure(why))
    }

    /// Only the system's check of the site's certificate: a login or a client certificate would have to ask.
    func webView(_ webView: WKWebView, didReceive challenge: URLAuthenticationChallenge) async -> (URLSession.AuthChallengeDisposition, URLCredential?) {
        challenge.protectionSpace.authenticationMethod == NSURLAuthenticationMethodServerTrust ? (.performDefaultHandling, nil) : (.cancelAuthenticationChallenge, nil)
    }

    // MARK: What the page may ask for: nothing

    /// Pop-ups don't open.
    func webView(_ webView: WKWebView, createWebViewWith configuration: WKWebViewConfiguration, for navigationAction: WKNavigationAction, windowFeatures: WKWindowFeatures) -> WKWebView? { nil }
    /// alert, confirm and prompt answer as dismissed.
    func webView(_ webView: WKWebView, runJavaScriptAlertPanelWithMessage message: String, initiatedByFrame frame: WKFrameInfo) async {}
    func webView(_ webView: WKWebView, runJavaScriptConfirmPanelWithMessage message: String, initiatedByFrame frame: WKFrameInfo) async -> Bool { false }
    func webView(_ webView: WKWebView, runJavaScriptTextInputPanelWithPrompt prompt: String, defaultText: String?, initiatedByFrame frame: WKFrameInfo) async -> String? { nil }
    func webView(_ webView: WKWebView, runOpenPanelWith parameters: WKOpenPanelParameters, initiatedByFrame frame: WKFrameInfo) async -> [URL]? { nil }
    func webView(_ webView: WKWebView, requestMediaCapturePermissionFor origin: WKSecurityOrigin, initiatedByFrame frame: WKFrameInfo, type: WKMediaCaptureType) async -> WKPermissionDecision { .deny }
}

/// One wait on WebKit, with a time limit and Cancel: the first of the three to happen ends it.
@MainActor
private final class Wait<Value: Sendable> {
    private let limit: TimeInterval, late: String, cancel: CancelToken
    private var continuation: CheckedContinuation<Value, Error>?
    private var timer: Timer?

    init(limit: TimeInterval, late: String, cancel: CancelToken) {
        self.limit = limit
        self.late = late
        self.cancel = cancel
    }

    func finish(_ result: Result<Value, Error>) {
        timer?.invalidate()
        timer = nil
        continuation?.resume(with: result)
        continuation = nil
    }

    func value(_ start: () -> Void) async throws -> Value where Value == Void {
        try await value { (_: @escaping @MainActor (Result<Value, Error>) -> Void) in start() }
    }

    func value(_ start: () -> Void) async throws -> Value where Value == Bool {
        try await value { (_: @escaping @MainActor (Result<Value, Error>) -> Void) in start() }
    }

    func value(_ start: (@escaping @MainActor (Result<Value, Error>) -> Void) -> Void) async throws -> Value {
        try await withCheckedThrowingContinuation { (waiting: CheckedContinuation<Value, Error>) in
            continuation = waiting
            let deadline = Date().addingTimeInterval(limit)
            let tick = Timer(timeInterval: 0.1, repeats: true) { [weak self] _ in
                MainActor.assumeIsolated {
                    guard let self else { return }
                    if self.cancel.isCancelled {
                        self.finish(.failure(CancellationError()))
                    } else if Date() >= deadline {
                        self.finish(.failure(PdfEditError(self.late)))
                    }
                }
            }
            RunLoop.main.add(tick, forMode: .common) // while a print operation holds the run loop too
            timer = tick
            start { [weak self] result in self?.finish(result) }
        }
    }
}
