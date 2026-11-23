import AppKit
import PdfCore
import PrintCore

/// Spell check where people type (roadmap 4.1; Windows' `Spelling`): the Mac's own dictionaries (NSSpellChecker, with the
/// words a person taught it), in the document's language, else the interface's (`SpellChecker.languages`), behind
/// PdfCore's `SpellChecker` rules (no digits, acronyms, single letters or addresses). Every editor people type into draws
/// the same red underline from `SpellChecker.check`: the paragraph editor of Edit Text & Images (an NSTextView), and the
/// text fields of notes, text boxes, callouts, replies, a run of page text and form fields (`SpellingField`). Each offers
/// the same menu on a misspelled word: suggestions, Ignore (for the session, everywhere), Add to Dictionary. Settings ›
/// "Check spelling as I type" turns it all off.
@MainActor
enum SpellCheck {
    /// NSSpellChecker in one of its languages, as PdfCore's `SpellingDictionary`; Add to Dictionary teaches it the word
    /// (macOS's Learn Spelling list), except in the self-test, which keeps the word for its run only.
    struct MacDictionary: SpellingDictionary {
        let spelling: MacSpelling
        let added: AddedWords
        /// The self-test's run: Add to Dictionary never writes the user's dictionary.
        let forRunOnly: Bool

        var language: String { spelling.language }
        func isKnown(_ word: String) -> Bool { added.contains(word) || spelling.isKnown(word) }
        func suggest(_ word: String) -> [String] { spelling.suggest(word) }

        func add(_ word: String) -> Bool {
            if forRunOnly {
                added.insert(word)
                return true
            }
            return Self.onMain {
                NSSpellChecker.shared.learnWord(word)
                return NSSpellChecker.shared.hasLearnedWord(word)
            }
        }

        private static func onMain<T: Sendable>(_ body: @MainActor () -> T) -> T {
            if Thread.isMainThread { return MainActor.assumeIsolated(body) }
            return DispatchQueue.main.sync { MainActor.assumeIsolated(body) }
        }
    }

    /// The words the self-test added (never the user's dictionary).
    final class AddedWords: @unchecked Sendable {
        private var words: Set<String> = []
        private let gate = NSLock()
        func insert(_ word: String) { gate.withLock { _ = words.insert(word) } }
        func contains(_ word: String) -> Bool { gate.withLock { words.contains(word) } }
    }

    private static var byDocument: [String: SpellChecker?] = [:]
    private static var byLanguage: [String: SpellChecker] = [:]
    private static let added = AddedWords()
    /// Documents' languages by the engine of the bytes they were read from (`DocumentWindowController.documentLanguage`).
    static var languages: [String: String?] = [:]

    /// Settings › "Check spelling as I type".
    static var on: Bool { AppSettings.spellCheck }

    /// The spell checker for text typed into a document whose text is in `documentLanguage` (nil: it doesn't say), one per
    /// language for the app's session (so Ignore holds everywhere); nil when spell check is off or the Mac has a dictionary
    /// for none of the languages tried.
    static func checker(_ documentLanguage: String?) -> SpellChecker? {
        guard on else { return nil }
        let ui = CoreLanguage.language
        let key = ui + "|" + (documentLanguage ?? "")
        if let known = byDocument[key] { return known }
        var found: SpellChecker?
        for tag in SpellChecker.languages(documentLanguage, ui, Locale.current.identifier) {
            guard let spelling = MacSpelling(language: tag) else { continue }
            if let had = byLanguage[spelling.language] {
                found = had
            } else {
                let made = SpellChecker(MacDictionary(spelling: spelling, added: added, forRunOnly: Report.isRunning))
                byLanguage[spelling.language] = made
                found = made
            }
            break
        }
        if found == nil { Report.progress("Spell check: the Mac has no dictionary for \(documentLanguage ?? "-") or the interface's language.") }
        byDocument[key] = found
        return found
    }

    /// Underlines the misspelled words of `view`'s text (a temporary spelling attribute, drawn as macOS draws its own);
    /// none with no checker. The view's own continuous checking stays off, so only these show.
    static func underline(_ view: NSTextView, _ checker: SpellChecker?) {
        guard let layout = view.layoutManager else { return }
        let text = view.string
        layout.removeTemporaryAttribute(.spellingState, forCharacterRange: NSRange(location: 0, length: (text as NSString).length))
        guard let checker else { return }
        for m in checker.check(text) {
            layout.addTemporaryAttribute(.spellingState, value: 1, // NSSpellingStateSpellingFlag
                                         forCharacterRange: NSRange(location: m.start, length: m.end - m.start))
        }
    }

    /// The editor's menu with the misspelled word at `index` first: its suggestions (or No Suggestions), Ignore and Add to
    /// Dictionary; macOS's own spelling items are left out. `changed` runs after the text or the dictionary changed.
    static func menu(_ menu: NSMenu, _ view: NSTextView, at index: Int, _ checker: SpellChecker?, changed: @escaping () -> Void) -> NSMenu {
        for item in menu.items where item.action.map({ NSStringFromSelector($0).hasSuffix("SpellingFromMenu:") }) == true {
            menu.removeItem(item)
        }
        while menu.items.first?.isSeparatorItem == true { menu.removeItem(at: 0) }
        guard let checker, let m = SpellChecker.at(checker.check(view.string), index) else { return menu }
        var items: [NSMenuItem] = []
        let suggestions = checker.suggestions(m.word)
        for s in suggestions {
            let item = SpellingAction.item(s) {
                // Only where the word still is (typed over since the menu opened: nothing changes).
                guard SpellChecker.correct(view.string, m, s) != nil else { return NSSound.beep() }
                let range = NSRange(location: m.start, length: m.end - m.start)
                if view.shouldChangeText(in: range, replacementString: s) {
                    view.replaceCharacters(in: range, with: s)
                    view.didChangeText()
                }
                changed()
            }
            item.attributedTitle = NSAttributedString(string: s, attributes: [.font: NSFont.boldSystemFont(ofSize: NSFont.systemFontSize)])
            items.append(item)
        }
        if suggestions.isEmpty {
            let none = NSMenuItem(title: loc("No Suggestions"), action: nil, keyEquivalent: "")
            none.isEnabled = false
            items.append(none)
        }
        items.append(.separator())
        items.append(SpellingAction.item(loc("Ignore Spelling")) {
            checker.ignore(m.word)
            changed()
        })
        items.append(SpellingAction.item(loc("Add to Dictionary")) {
            if checker.add(m.word) {
                changed()
            } else if let window = view.window {
                let alert = NSAlert()
                alert.messageText = loc("Couldn't add the word")
                alert.informativeText = loc("macOS didn't add “{0}” to your dictionary. Try again later.", m.word)
                alert.beginSheetModal(for: window)
            }
        })
        items.append(.separator())
        for (i, item) in items.enumerated() { menu.insertItem(item, at: i) }
        return menu
    }
}

extension DocumentWindowController {
    /// The language the document says its text is in (its /Lang), read once for each version of its bytes; nil when it
    /// says none.
    var documentLanguage: String? {
        guard let session = pdf.session else { return nil }
        let key = "\(ObjectIdentifier(session.engine).hashValue)-\(session.data.count)"
        if let known = SpellCheck.languages[key] { return known }
        let language = SpellChecker.documentLanguage(session.data, session.password)
        if SpellCheck.languages.count > 64 { SpellCheck.languages.removeAll() }
        SpellCheck.languages[key] = .some(language)
        return language
    }
}

/// A menu item that runs a closure.
final class SpellingAction: NSObject {
    private let action: () -> Void
    private init(_ action: @escaping () -> Void) { self.action = action }

    @MainActor
    static func item(_ title: String, _ action: @escaping () -> Void) -> NSMenuItem {
        let target = SpellingAction(action)
        let item = NSMenuItem(title: title, action: #selector(run), keyEquivalent: "")
        item.target = target
        item.representedObject = target // the item keeps its target
        return item
    }

    @objc private func run() { action() }
}

/// A text field people type into with spell check as they type (`SpellCheck`): its field editor's text underlined after
/// each change, the menu on a misspelled word. `documentLanguage` picks the dictionary; spell check off, it's a plain field.
final class SpellingField: NSTextField {
    var documentLanguage: String?
    private var checker: SpellChecker? { SpellCheck.checker(documentLanguage) }

    private var editor: NSTextView? { currentEditor() as? NSTextView }

    func recheck() {
        guard let editor else { return }
        SpellCheck.underline(editor, checker)
    }

    override func becomeFirstResponder() -> Bool {
        let ok = super.becomeFirstResponder()
        if ok { DispatchQueue.main.async { [weak self] in self?.recheck() } }
        return ok
    }

    override func textDidChange(_ notification: Notification) {
        super.textDidChange(notification)
        recheck()
    }

    override func textDidEndEditing(_ notification: Notification) {
        // The field editor is shared: its underlines go with this field's text.
        if let editor { SpellCheck.underline(editor, nil) }
        super.textDidEndEditing(notification)
    }

    /// The field editor's menu (it asks its delegate, this field).
    @objc func textView(_ view: NSTextView, menu: NSMenu, for event: NSEvent, at charIndex: Int) -> NSMenu? {
        SpellCheck.menu(menu, view, at: charIndex, checker) { [weak self] in self?.recheck() }
    }
}
