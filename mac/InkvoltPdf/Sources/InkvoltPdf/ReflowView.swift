import AppKit
import PdfCore
import PrintCore
import WebKit

/// The Reflow view (roadmap 4.16, View › Reflow, ⌘3): the document as one readable column in the window, in place of the
/// pages. The column is PdfCore's `Reflow` (Export's HTML: no script, no request, a Content-Security-Policy), shown in a
/// WKWebView with page scripts off, a data store nothing outlives, and nothing loaded but that page at `Reflow.address`
/// (only the app's own scripts run, in their own world: the page at the top, a scroll, the look). The text size follows
/// the view's zoom, the colors Dark Pages; the page is kept both ways (`ReflowPosition`); a web or mail link opens in the
/// browser. Read-only: only `Reflow.runsAction`'s commands work while it shows. As on Windows.
@MainActor
final class ReflowView: NSObject, WKNavigationDelegate, WKUIDelegate {
    private weak var controller: DocumentWindowController?
    /// What shows in the window in place of the pages: the web view, or a message.
    let host = NSView()
    private(set) var web: WKWebView?
    private var position: ReflowPosition?
    private var document: ReflowDocument?
    private var making: CancelToken?
    private var poll: Timer?
    private var asking = false
    private var driving = false // the view is sending the page view to its page
    private var allowLoad = false
    /// The document changed while it shows: laid out again once idle.
    private var stale = false
    private(set) var zoom = 1.0
    private(set) var isShown = false
    /// What it shows now (the self-test reads it): off, preparing, showing, nothing to reflow, failed.
    private(set) var state = "off"
    /// The self-test: addresses links opened (nil: open them for real).
    var testOpened: [String]?

    init(controller: DocumentWindowController) {
        self.controller = controller
        super.init()
        host.translatesAutoresizingMaskIntoConstraints = false
        host.isHidden = true
        NotificationCenter.default.addObserver(self, selector: #selector(restyle), name: PageRenderer.darkPagesChanged, object: nil)
    }

    private var look: ReflowLook { ReflowLook(textScale: 1, zoom: zoom, darkPages: AppSettings.darkPages) }

    private static var now: Int64 { Int64(ProcessInfo.processInfo.systemUptime * 1000) }

    // MARK: On and off

    /// Shows the column from the page in view.
    func show(at page: Int) {
        guard let c = controller, !isShown, c.engine.pageCount > 0 else { return }
        isShown = true
        position = ReflowPosition(c.engine.pageCount)
        position?.enter(page)
        host.isHidden = false
        make()
    }

    /// Back to the pages; the page Reflow was at.
    func hide() -> Int? {
        guard isShown else { return nil }
        let page = position?.leave()
        isShown = false
        state = "off"
        making?.cancel()
        making = nil
        poll?.invalidate()
        poll = nil
        web?.navigationDelegate = nil
        web?.uiDelegate = nil
        web = nil
        document = nil
        position = nil
        stale = false
        clearHost()
        host.isHidden = true
        return page
    }

    func stop() {
        _ = hide()
        NotificationCenter.default.removeObserver(self)
    }

    // MARK: The column

    /// Lays the document out as one column (off the main thread) and shows it at the page kept.
    private func make() {
        guard let c = controller, let session = c.pdf.session else { return }
        making?.cancel()
        let cancel = CancelToken()
        making = cancel
        stale = false
        showMessage(loc("Putting the text in one column…"), busy: true)
        state = "preparing"
        let (data, password, title) = (session.data, session.password, c.pdf.name)
        Task.detached(priority: .userInitiated) {
            let result = Result { try Reflow.make(data, password: password, title: title, cancel: cancel) }
            await MainActor.run { self.made(result, cancel) }
        }
    }

    private func made(_ result: Result<ReflowDocument, Error>, _ cancel: CancelToken) {
        guard isShown, making === cancel, !cancel.isCancelled, let c = controller else { return }
        making = nil
        switch result {
        case .failure(let error):
            if error is CancellationError { return }
            showMessage(loc("The Reflow view couldn't be made: {0}", error.localizedDescription))
            state = "failed"
        case .success(let doc) where !doc.hasContent:
            showMessage(loc("These pages have no text to reflow. If they're scans, use Recognize Text first."))
            state = "nothing to reflow"
        case .success(let doc):
            document = doc
            let kept = position?.page ?? c.pages.currentPage
            position = ReflowPosition(doc.pages)
            position?.enter(kept) // the page kept since Reflow opened, not the page view's as it relays out
            load(Reflow.style(doc.html, look))
        }
    }

    private func load(_ page: String) {
        let view = web ?? makeWeb()
        if view.superview == nil {
            clearHost()
            pin(view)
            view.window?.makeFirstResponder(view) // the keys scroll the column; Copy and Select All are its own
        }
        view.underPageBackgroundColor = Self.paper
        allowLoad = true
        view.loadHTMLString(page, baseURL: URL(string: Reflow.address))
    }

    private static var paper: NSColor {
        AppSettings.darkPages ? NSColor(srgbRed: 0x1e / 255, green: 0x1e / 255, blue: 0x1e / 255, alpha: 1) : .white
    }

    /// Page scripts, pop-ups, downloads, media and the online list of bad sites are off; nothing is kept.
    private func makeWeb() -> WKWebView {
        let config = WKWebViewConfiguration()
        config.websiteDataStore = .nonPersistent()
        config.defaultWebpagePreferences.allowsContentJavaScript = false
        config.preferences.javaScriptCanOpenWindowsAutomatically = false
        config.preferences.isFraudulentWebsiteWarningEnabled = false
        config.preferences.isElementFullscreenEnabled = false
        config.mediaTypesRequiringUserActionForPlayback = .all
        config.allowsAirPlayForMediaPlayback = false
        let view = WKWebView(frame: host.bounds, configuration: config)
        view.navigationDelegate = self
        view.uiDelegate = self
        view.allowsBackForwardNavigationGestures = false
        view.allowsLinkPreview = false
        view.allowsMagnification = false
        view.setAccessibilityLabel(loc("The document's text in one column"))
        web = view
        return view
    }

    private func clearHost() {
        for v in host.subviews { v.removeFromSuperview() }
    }

    private func pin(_ view: NSView) {
        view.translatesAutoresizingMaskIntoConstraints = false
        host.addSubview(view)
        NSLayoutConstraint.activate([
            view.leadingAnchor.constraint(equalTo: host.leadingAnchor), view.trailingAnchor.constraint(equalTo: host.trailingAnchor),
            view.topAnchor.constraint(equalTo: host.topAnchor), view.bottomAnchor.constraint(equalTo: host.bottomAnchor),
        ])
    }

    /// A message in place of the column: preparing (with a spinner), or why there is none (with Back to Pages).
    private func showMessage(_ text: String, busy: Bool = false) {
        poll?.invalidate()
        poll = nil
        web?.navigationDelegate = nil
        web = nil
        clearHost()
        let label = NSTextField(wrappingLabelWithString: text)
        label.alignment = .center
        label.preferredMaxLayoutWidth = 440
        label.setAccessibilityRole(.staticText)
        var views: [NSView] = []
        if busy {
            let spinner = NSProgressIndicator()
            spinner.style = .spinning
            spinner.controlSize = .small
            spinner.startAnimation(nil)
            views.append(spinner)
        }
        views.append(label)
        if !busy { views.append(NSButton(title: loc("Back to Pages"), target: self, action: #selector(backClicked))) }
        let stack = NSStackView(views: views)
        stack.orientation = .vertical
        stack.spacing = 14
        stack.translatesAutoresizingMaskIntoConstraints = false
        host.addSubview(stack)
        NSLayoutConstraint.activate([
            stack.centerXAnchor.constraint(equalTo: host.centerXAnchor), stack.centerYAnchor.constraint(equalTo: host.centerYAnchor),
            stack.widthAnchor.constraint(lessThanOrEqualToConstant: 460),
        ])
        NSAccessibility.post(element: label, notification: .layoutChanged)
    }

    @objc private func backClicked() { controller?.setReflow(false) }

    // MARK: Where the reader is

    func webView(_ webView: WKWebView, didFinish navigation: WKNavigation!) {
        guard webView === web, isShown, let position else { return }
        run(Reflow.scrollScript(position.page))
        state = "showing"
        poll?.invalidate()
        poll = Timer.scheduledTimer(withTimeInterval: 0.4, repeats: true) { [weak self] _ in
            MainActor.assumeIsolated { self?.pollTop() }
        }
    }

    /// Which page is at the top of the view; the page box follows it.
    private func pollTop() {
        guard !asking, let web, isShown else { return }
        asking = true
        web.evaluateJavaScript(Reflow.topPageScript, in: nil, in: .defaultClient) { [weak self] result in
            MainActor.assumeIsolated {
                guard let self else { return }
                self.asking = false
                guard self.isShown, let position = self.position, let c = self.controller else { return }
                let id = (try? result.get()) as? String
                if let page = position.scrolled(Reflow.pageOf(id, position.pages), Self.now) {
                    self.driving = true // the page view's own reports while it moves aren't the reader's
                    c.go(page)
                    self.driving = false
                }
                if self.stale && !c.isBusy { self.make() } // the document changed: laid out again
            }
        }
    }

    /// The page view moved (the page box, Next Page, a bookmark, a thumbnail): the view scrolls there.
    func viewerMoved(_ page: Int) {
        guard !driving, isShown, web != nil, let position else { return }
        if let p = position.viewerMoved(page, Self.now) { run(Reflow.scrollScript(p)) }
    }

    /// The page view was laid out again under the view (a resize, a zoom): the page it settles on isn't the reader's.
    func viewerRelaid() { position?.viewerRelaid(Self.now) }

    /// The document changed (an edit, undo, a reload): laid out again once idle.
    func contentChanged() {
        if isShown { stale = true }
        if isShown && web == nil && making == nil { make() } // a message showed: try again now
    }

    /// Zoom In (+1), Zoom Out (-1) or Actual Size (0): the text's size.
    func zoom(_ steps: Int) {
        zoom = steps == 0 ? 1 : Reflow.zoomStep(zoom, steps)
        restyle()
    }

    /// Dark Pages or the zoom changed: the view takes the new look where it is, the page kept back at the top in the same
    /// script, so the page box never sees the page in between.
    @objc func restyle() {
        guard isShown, document != nil, let web else { return }
        web.underPageBackgroundColor = Self.paper
        run(Reflow.restyleScript(look) + ";" + Reflow.scrollScript(position?.page ?? 0))
    }

    private func run(_ script: String) {
        web?.evaluateJavaScript(script, in: nil, in: .defaultClient) { _ in }
    }

    /// The self-test: what `script` answers in the view (in the app's own world, as every script here), as text.
    func evaluate(_ script: String) async -> String? {
        guard let web else { return nil }
        let answer = try? await web.evaluateJavaScript(script, in: nil, contentWorld: .defaultClient)
        return answer.map { "\($0)" }
    }

    /// The self-test: the page at the top of the view, as the view reports it.
    func topPage() async -> Int? { Reflow.pageOf(await evaluate(Reflow.topPageScript), position?.pages ?? 0) }

    /// The page kept (nil while it doesn't show).
    var page: Int? { position?.page }

    /// The self-test: page scripts are off in the view.
    var runsPageScripts: Bool { web?.configuration.defaultWebpagePreferences.allowsContentJavaScript ?? true }

    /// The self-test: scrolls the view itself to `page`, as a reader would.
    func scrollAsReader(_ page: Int) { run(Reflow.scrollScript(page)) }

    // MARK: Links: the page stays the only one

    func webView(_ webView: WKWebView, decidePolicyFor navigationAction: WKNavigationAction, preferences: WKWebpagePreferences) async -> (WKNavigationActionPolicy, WKWebpagePreferences) {
        preferences.allowsContentJavaScript = false
        if allowLoad && navigationAction.navigationType == .other && navigationAction.targetFrame?.isMainFrame == true {
            allowLoad = false
            return (.allow, preferences)
        }
        if let url = navigationAction.request.url, navigationAction.navigationType == .linkActivated {
            follow(url.absoluteString)
        }
        return (.cancel, preferences)
    }

    /// A link clicked in the view: a place in the document scrolls there; a web or mail address opens in the browser;
    /// anything else does nothing.
    func follow(_ uri: String) {
        let link = Reflow.follow(uri, document?.pages ?? controller?.engine.pageCount ?? 1)
        switch link.kind {
        case .external:
            guard let address = link.address, let url = URL(string: address) else { return }
            if testOpened != nil { testOpened?.append(address) } else { NSWorkspace.shared.open(url) }
        case .inDocument where link.page >= 0:
            run(Reflow.scrollScript(link.page))
        default:
            break
        }
    }

    /// The page's process died: say so, with Back to Pages.
    func webViewWebContentProcessDidTerminate(_ webView: WKWebView) {
        guard webView === web, isShown else { return }
        showMessage(loc("The Reflow view couldn't be made: {0}", loc("The view stopped.")))
        state = "failed"
    }

    /// Pop-ups don't open (a link with a target opens as a click on it does).
    func webView(_ webView: WKWebView, createWebViewWith configuration: WKWebViewConfiguration, for navigationAction: WKNavigationAction,
                 windowFeatures: WKWindowFeatures) -> WKWebView? {
        if let url = navigationAction.request.url { follow(url.absoluteString) }
        return nil
    }
}
