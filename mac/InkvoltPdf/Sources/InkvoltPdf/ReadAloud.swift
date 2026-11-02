import AppKit
import AVFoundation
import PdfCore

/// What reads the text out: macOS's voices through `AVSpeechSynthesizer`, or the self-test's silent stand-in.
@MainActor
protocol ReadAloudSpeaker: AnyObject {
    /// A word of the text being spoken starts (its UTF-16 range in that text).
    var onWord: ((_ start: Int, _ end: Int) -> Void)? { get set }
    /// The text has been spoken to its end (not after `stop`).
    var onFinished: (() -> Void)? { get set }
    func speak(_ text: String, voice: String?, speed: Double)
    func pause()
    func resume()
    func stop()
}

/// The voices macOS offers to apps, the user's language first.
@MainActor
enum ReadAloudVoices {
    static func all() -> [(id: String, title: String)] {
        let language = Locale.current.language.languageCode?.identifier ?? "en"
        return AVSpeechSynthesisVoice.speechVoices()
            .sorted { a, b in
                let aMine = a.language.hasPrefix(language), bMine = b.language.hasPrefix(language)
                if aMine != bMine { return aMine }
                if a.quality != b.quality { return a.quality.rawValue > b.quality.rawValue }
                return a.name.localizedStandardCompare(b.name) == .orderedAscending
            }
            .map { ($0.identifier, "\($0.name) (\($0.language))") }
    }
}

/// `AVSpeechSynthesizer`: an utterance per paragraph, its words reported as they start. Only the utterance spoken last
/// reports: a stopped one's late callbacks are dropped.
@MainActor
final class SystemSpeaker: NSObject, ReadAloudSpeaker, AVSpeechSynthesizerDelegate {
    var onWord: ((Int, Int) -> Void)?
    var onFinished: (() -> Void)?
    private let synthesizer = AVSpeechSynthesizer()
    private var current: ObjectIdentifier?

    override init() {
        super.init()
        synthesizer.delegate = self
    }

    func speak(_ text: String, voice: String?, speed: Double) {
        let utterance = AVSpeechUtterance(string: text)
        if let voice, let v = AVSpeechSynthesisVoice(identifier: voice) { utterance.voice = v }
        let rate = AVSpeechUtteranceDefaultSpeechRate * Float(speed)
        utterance.rate = min(max(rate, AVSpeechUtteranceMinimumSpeechRate), AVSpeechUtteranceMaximumSpeechRate)
        current = ObjectIdentifier(utterance)
        synthesizer.speak(utterance)
    }

    func pause() { synthesizer.pauseSpeaking(at: .word) }
    func resume() { synthesizer.continueSpeaking() }

    func stop() {
        current = nil
        synthesizer.stopSpeaking(at: .immediate)
    }

    // The delegate may be called off the main thread: each call hops to the main actor with plain values.
    nonisolated func speechSynthesizer(_ synthesizer: AVSpeechSynthesizer, willSpeakRangeOfSpeechString characterRange: NSRange,
                                       utterance: AVSpeechUtterance) {
        let id = ObjectIdentifier(utterance), start = characterRange.location, end = characterRange.location + characterRange.length
        Task { @MainActor in
            guard self.current == id else { return }
            self.onWord?(start, end)
        }
    }

    nonisolated func speechSynthesizer(_ synthesizer: AVSpeechSynthesizer, didFinish utterance: AVSpeechUtterance) {
        let id = ObjectIdentifier(utterance)
        Task { @MainActor in
            guard self.current == id else { return }
            self.current = nil
            self.onFinished?()
        }
    }
}

/// The self-test's speaker: silent, it keeps what it was asked to say; the test ends each paragraph with `finish()`.
@MainActor
final class RecordingSpeaker: ReadAloudSpeaker {
    var onWord: ((Int, Int) -> Void)?
    var onFinished: (() -> Void)?
    private(set) var spoken: [(text: String, voice: String?, speed: Double)] = []
    private(set) var paused = false
    private(set) var stopped = 0

    func speak(_ text: String, voice: String?, speed: Double) {
        spoken.append((text, voice, speed))
        paused = false
    }

    func pause() { paused = true }
    func resume() { paused = false }
    func stop() { stopped += 1 }
    func word(_ start: Int, _ end: Int) { onWord?(start, end) }
    func finish() { onFinished?() }
}

/// Read Aloud (View › Read Aloud, ⇧⌘Y; the Windows app's `ReadAloud`): reads the document from the top of the view (or
/// just the selection) with a macOS voice, paragraph by paragraph (`ReadAloudText`), the sentence and word being read
/// highlighted and followed. A bar over the pages: previous paragraph, pause, next paragraph, stop, the page, the voice
/// and the speed (0.75×-2×). One per window; it stops when the document changes or the window closes. VoiceOver keeps
/// speaking on its own: this is a separate voice the user starts and stops.
@MainActor
final class ReadAloud {
    static let speeds = [0.75, 1, 1.25, 1.5, 1.75, 2]
    /// The voice and speed chosen last (this session), used by every window, as on Windows.
    private static var voiceId: String?
    private static var speed = 1.0

    private weak var controller: DocumentWindowController?
    let bar = ReadAloudBar()
    private(set) var speaker: ReadAloudSpeaker
    private let voices: [(id: String, title: String)]

    private(set) var isActive = false
    private(set) var isPaused = false
    private(set) var page = 0
    private(set) var chunks: [SpeechChunk] = []
    private(set) var chunkIndex = 0
    private(set) var speaking: SpeechChunk?
    /// Reading a selection: where it ends (nothing after it is read).
    private var end: (page: Int, caret: Int)?
    private var pageText: PageText?

    init(controller: DocumentWindowController) {
        self.controller = controller
        speaker = SystemSpeaker()
        voices = ReadAloudVoices.all()
        bar.isHidden = true
        bar.setVoices(voices.map(\.title), selected: voices.firstIndex { $0.id == Self.voiceId } ?? 0)
        bar.setSpeeds(Self.speeds.map { Self.speedTitle($0) }, selected: Self.speeds.firstIndex(of: Self.speed) ?? 1)
        if Self.voiceId == nil { Self.voiceId = voices.first?.id }
        bar.onPrevious = { [weak self] in self?.skip(-1) }
        bar.onPause = { [weak self] in self?.togglePause() }
        bar.onNext = { [weak self] in self?.skip(1) }
        bar.onStop = { [weak self] in self?.stop() }
        bar.onVoice = { [weak self] i in
            guard let self, i >= 0, i < self.voices.count else { return }
            Self.voiceId = self.voices[i].id
            self.restartChunk()
        }
        bar.onSpeed = { [weak self] i in
            guard let self, i >= 0, i < Self.speeds.count else { return }
            Self.speed = Self.speeds[i]
            self.restartChunk()
        }
        wire()
    }

    private func wire() {
        speaker.onWord = { [weak self] s, e in self?.wordStarted(s, e) }
        speaker.onFinished = { [weak self] in self?.chunkEnded() }
    }

    /// The self-test's silent speaker in place of macOS's voices (reading stops first).
    func use(_ other: ReadAloudSpeaker) {
        stop()
        speaker = other
        wire()
    }

    static func speedTitle(_ s: Double) -> String {
        let f = NumberFormatter()
        f.maximumFractionDigits = 2
        f.minimumFractionDigits = 0
        return (f.string(from: NSNumber(value: s)) ?? "\(s)") + "×"
    }

    var voiceTitle: String { voices.first { $0.id == Self.voiceId }?.title ?? "" }
    var speed: Double { Self.speed }

    /// What the bar's status says, for VoiceOver and the self-test.
    var state: String {
        guard isActive else { return "stopped" }
        return "\(isPaused ? "paused" : "reading") page \(page + 1) paragraph \(chunkIndex + 1)/\(chunks.count)"
    }

    // MARK: Start, stop, pause, skip

    /// Starts reading from the selection, else from the top of the view; reading already: stops.
    func toggle() {
        if isActive { return stop() }
        guard let controller else { return }
        if voices.isEmpty && !(speaker is RecordingSpeaker) {
            controller.notify("No voices are installed. Add one in System Settings › Accessibility › Spoken Content.")
            return
        }
        let pages = controller.pages
        isActive = true
        isPaused = false
        bar.isHidden = false
        var startPage: Int, from: Int
        if let s = pages.selection, !s.isEmpty {
            (startPage, from) = s.first
            end = s.last
        } else {
            let v = pages.visibleRect
            let top = pages.page(at: NSPoint(x: v.midX, y: v.minY))
            startPage = top?.page ?? pages.currentPage
            from = 0
            end = nil
            if let top, top.y > 0, let text = try? controller.engine.text(startPage), !text.isEmpty {
                from = text.lineAt(text.hitTest(36, top.y + 4)).start
            }
        }
        loadPage(startPage, from: from)
        chunkIndex = 0
        speakNextAvailable()
    }

    func stop() {
        let wasActive = isActive
        isActive = false
        isPaused = false
        speaker.stop()
        speaking = nil
        chunks = []
        controller?.pages.speech = nil
        bar.isHidden = true
        if wasActive { updateBar() }
    }

    func togglePause() {
        guard isActive else { return }
        isPaused.toggle()
        if isPaused { speaker.pause() } else { speaker.resume() }
        updateBar()
    }

    /// The previous or next paragraph (across pages).
    func skip(_ direction: Int) {
        guard isActive else { return }
        speaker.stop()
        isPaused = false
        var index = chunkIndex + direction
        if index < 0 {
            // Back to the last paragraph of the page before.
            var p = page - 1
            while p >= 0 {
                loadPage(p, from: 0)
                if !chunks.isEmpty {
                    chunkIndex = chunks.count - 1
                    return speak(chunks[chunkIndex])
                }
                p -= 1
            }
            loadPage(0, from: 0)
            index = 0
        }
        chunkIndex = index
        speakNextAvailable()
    }

    // MARK: Reading

    /// Speaks the current paragraph, going on to the following pages when this one has nothing (more) to read.
    private func speakNextAvailable() {
        guard let controller else { return stop() }
        while chunkIndex >= chunks.count {
            if let end, page >= end.page { return stop() }
            if page + 1 >= controller.engine.pageCount { return stop() }
            loadPage(page + 1, from: 0)
            chunkIndex = 0
        }
        speak(chunks[chunkIndex])
    }

    private func loadPage(_ p: Int, from: Int) {
        page = p
        pageText = try? controller?.engine.text(p)
        let to = end.map { $0.page == p ? $0.caret : Int.max } ?? Int.max
        chunks = ReadAloudText.chunks(p, pageText?.text ?? "", from: from, to: to)
    }

    private func speak(_ chunk: SpeechChunk) {
        speaking = chunk
        updateBar()
        speaker.speak(chunk.text, voice: Self.voiceId, speed: Self.speed)
        if isPaused { speaker.pause() }
        // Show where reading starts right away (the first word's callback may come a moment later).
        let units = Array(chunk.text.utf16)
        wordStarted(0, units.firstIndex(of: 32) ?? units.count)
    }

    private func chunkEnded() {
        guard isActive else { return }
        chunkIndex += 1
        speakNextAvailable()
    }

    /// Reads the current paragraph again from the sentence being read (a new voice or speed).
    private func restartChunk() {
        guard isActive, let chunk = speaking else { return }
        let at = controller?.pages.speech.map { Self.sentence(in: chunk, around: $0.wordInChunk.start).start } ?? 0
        speaker.stop()
        let rest = at == 0 ? chunk : chunk.suffix(from: at)
        chunks[chunkIndex] = rest
        speak(rest)
    }

    /// Highlights the word starting and its sentence, and keeps them in view.
    private func wordStarted(_ start: Int, _ end: Int) {
        guard isActive, let chunk = speaking, let text = pageText, let pages = controller?.pages, !chunk.source.isEmpty else { return }
        let word = chunk.sourceRange(start, end)
        let s = Self.sentence(in: chunk, around: start)
        let sentence = chunk.sourceRange(s.start, s.end)
        pages.speech = PagesView.SpeechMarks(page: chunk.page, sentence: (sentence.start, min(sentence.end, text.length)),
                                            word: (word.start, min(word.end, text.length)), wordInChunk: (start, end))
        pages.followSpeech()
    }

    /// The sentence of the chunk around spoken unit `at`: from after the last ". " (or "! ", "? ") before it to the next.
    static func sentence(in chunk: SpeechChunk, around at: Int) -> (start: Int, end: Int) {
        let u = Array(chunk.text.utf16)
        guard !u.isEmpty else { return (0, 0) }
        let stops = Set(".!?…".utf16)
        let at = min(max(at, 0), u.count - 1)
        var start = at
        while start > 0 && !(u[start - 1] == 32 && start >= 2 && stops.contains(u[start - 2])) { start -= 1 }
        var end = at
        while end < u.count && !(stops.contains(u[end]) && (end + 1 == u.count || u[end + 1] == 32)) { end += 1 }
        return (start, min(end + 1, u.count))
    }

    private func updateBar() {
        bar.update(paused: isPaused, status: isActive ? "Page \(page + 1)" : "")
    }
}

/// Read Aloud's bar over the pages.
@MainActor
final class ReadAloudBar: NSView {
    var onPrevious: (() -> Void)?
    var onPause: (() -> Void)?
    var onNext: (() -> Void)?
    var onStop: (() -> Void)?
    var onVoice: ((Int) -> Void)?
    var onSpeed: ((Int) -> Void)?
    let previousButton = ReadAloudBar.button("backward.end.fill", "Previous Paragraph")
    let pauseButton = ReadAloudBar.button("pause.fill", "Pause")
    let nextButton = ReadAloudBar.button("forward.end.fill", "Next Paragraph")
    let stopButton = ReadAloudBar.button("stop.fill", "Stop Reading (⇧⌘Y)")
    let statusLabel = NSTextField(labelWithString: "")
    let voicePopup = NSPopUpButton()
    let speedPopup = NSPopUpButton()

    private static func button(_ symbol: String, _ label: String) -> NSButton {
        let image = NSImage(systemSymbolName: symbol, accessibilityDescription: label) ?? NSImage()
        let b = NSButton(image: image, target: nil, action: nil)
        b.bezelStyle = .accessoryBarAction
        b.isBordered = false
        b.toolTip = label
        b.setAccessibilityLabel(label)
        return b
    }

    override init(frame: NSRect) {
        super.init(frame: frame)
        let icon = NSImageView(image: NSImage(systemSymbolName: "speaker.wave.2.fill", accessibilityDescription: nil) ?? NSImage())
        icon.contentTintColor = .controlAccentColor
        let title = NSTextField(labelWithString: "Read Aloud")
        title.font = .systemFont(ofSize: NSFont.smallSystemFontSize, weight: .semibold)
        statusLabel.font = .systemFont(ofSize: NSFont.smallSystemFontSize)
        statusLabel.textColor = .secondaryLabelColor
        statusLabel.widthAnchor.constraint(greaterThanOrEqualToConstant: 52).isActive = true
        for (b, sel) in [(previousButton, #selector(previous)), (pauseButton, #selector(pause)), (nextButton, #selector(next)), (stopButton, #selector(stop))] {
            b.target = self
            b.action = sel
        }
        voicePopup.target = self
        voicePopup.action = #selector(voiceChosen)
        voicePopup.controlSize = .small
        voicePopup.setAccessibilityLabel("Voice")
        voicePopup.toolTip = "Voice"
        voicePopup.widthAnchor.constraint(lessThanOrEqualToConstant: 240).isActive = true
        speedPopup.target = self
        speedPopup.action = #selector(speedChosen)
        speedPopup.controlSize = .small
        speedPopup.setAccessibilityLabel("Speed")
        speedPopup.toolTip = "Speed"
        let stack = NSStackView(views: [icon, title, previousButton, pauseButton, nextButton, stopButton, statusLabel, voicePopup, speedPopup])
        stack.orientation = .horizontal
        stack.spacing = 8
        stack.edgeInsets = NSEdgeInsets(top: 4, left: 12, bottom: 4, right: 12)
        stack.translatesAutoresizingMaskIntoConstraints = false
        addSubview(stack)
        NSLayoutConstraint.activate([
            stack.leadingAnchor.constraint(equalTo: leadingAnchor),
            stack.trailingAnchor.constraint(lessThanOrEqualTo: trailingAnchor),
            stack.topAnchor.constraint(equalTo: topAnchor),
            stack.bottomAnchor.constraint(equalTo: bottomAnchor),
        ])
        setAccessibilityElement(true)
        setAccessibilityRole(.group)
        setAccessibilityLabel("Read Aloud")
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError("not used") }

    override func draw(_ dirtyRect: NSRect) {
        NSColor.controlBackgroundColor.setFill()
        bounds.fill()
        NSColor.separatorColor.setFill()
        NSRect(x: 0, y: 0, width: bounds.width, height: 1).fill()
    }

    func setVoices(_ titles: [String], selected: Int) {
        voicePopup.removeAllItems()
        voicePopup.addItems(withTitles: titles)
        if selected < titles.count { voicePopup.selectItem(at: selected) }
        voicePopup.isEnabled = !titles.isEmpty
    }

    func setSpeeds(_ titles: [String], selected: Int) {
        speedPopup.removeAllItems()
        speedPopup.addItems(withTitles: titles)
        speedPopup.selectItem(at: selected)
    }

    func update(paused: Bool, status: String) {
        let label = paused ? "Resume" : "Pause"
        pauseButton.image = NSImage(systemSymbolName: paused ? "play.fill" : "pause.fill", accessibilityDescription: label)
        pauseButton.toolTip = label
        pauseButton.setAccessibilityLabel(label)
        statusLabel.stringValue = status
    }

    @objc private func previous() { onPrevious?() }
    @objc private func pause() { onPause?() }
    @objc private func next() { onNext?() }
    @objc private func stop() { onStop?() }
    @objc private func voiceChosen() { onVoice?(voicePopup.indexOfSelectedItem) }
    @objc private func speedChosen() { onSpeed?(speedPopup.indexOfSelectedItem) }
}

// MARK: The window's command

extension DocumentWindowController {
    /// View › Read Aloud (⇧⌘Y): starts, or stops when reading.
    @objc func toggleReadAloud(_ sender: Any?) { readAloud.toggle() }
}
