import AppKit
import PdfCore

/// Bookmarks (the Windows app's bookmark pane): Pages › Add Bookmark (⌘D) adds one for the page shown, after the bookmark
/// selected; the sidebar's Bookmarks list renames (Return, or its menu), deletes (Delete) and moves them (drag, also under
/// another bookmark). Each change is one edit (`Bookmarks.setOutline` over the tree read from the current bytes), so a
/// signed file gets it appended.
extension DocumentWindowController {
    func wireBookmarks() {
        sidebar.onAddBookmark = { [weak self] in self?.addBookmark(nil) }
        sidebar.onRenameBookmark = { [weak self] path in self?.askRenameBookmark(path) }
        sidebar.onDeleteBookmark = { [weak self] path in
            guard let self else { return }
            Task { await self.deleteBookmark(path) }
        }
        sidebar.onMoveBookmark = { [weak self] from, parent, index in
            guard let self else { return }
            Task { await self.moveBookmark(from, parent: parent, index: index) }
        }
    }

    private static func short(_ title: String) -> String { title.count > 40 ? String(title.prefix(39)) + "…" : title }

    /// The bookmarks of the document's current bytes.
    func readBookmarks() -> [Bookmark] {
        guard let s = pdf.session else { return [] }
        return (try? Bookmarks.read(s.data, s.password)) ?? []
    }

    /// Pages › Add Bookmark: a bookmark to the page shown (from the top of what is shown), its title asked.
    @objc func addBookmark(_ sender: Any?) {
        let page = pages.currentPage
        let shownTop = Double(scrollView.contentView.bounds.minY - pages.pageRects[page].minY)
        let top: Double? = shownTop > 1 ? min(shownTop, engine.page(page).height) : nil
        let after = sidebar.selectedBookmark
        askTitle("Add Bookmark", initial: "Page \(page + 1)", button: "Add") { [weak self] title in
            guard let self else { return }
            Task { await self.addBookmark(title: title, page: page, top: top, after: after) }
        }
    }

    func askRenameBookmark(_ path: [Int]) {
        guard let old = try? BookmarkTree.at(readBookmarks(), path) else { return }
        askTitle("Rename Bookmark", initial: old.title, button: "Rename") { [weak self] title in
            guard let self, title != old.title else { return }
            Task { await self.renameBookmark(path, to: title) }
        }
    }

    /// A bookmark title in a sheet (the self-test's `testText` answers it).
    private func askTitle(_ heading: String, initial: String, button: String, done: @escaping (String) -> Void) {
        if let testText {
            done(testText)
            return
        }
        guard let window else { return }
        let alert = NSAlert()
        alert.messageText = heading
        let field = NSTextField(string: initial)
        field.frame = NSRect(x: 0, y: 0, width: 280, height: 24)
        field.setAccessibilityLabel("Bookmark title")
        alert.accessoryView = field
        alert.addButton(withTitle: button)
        alert.addButton(withTitle: "Cancel")
        alert.window.initialFirstResponder = field
        alert.beginSheetModal(for: window) { response in
            MainActor.assumeIsolated {
                let title = field.stringValue.replacingOccurrences(of: "\n", with: " ").trimmingCharacters(in: .whitespaces)
                guard response == .alertFirstButtonReturn, !title.isEmpty else { return }
                done(title)
            }
        }
    }

    /// One change to the bookmark tree as an edit; the bookmark at `select` is selected afterwards.
    @discardableResult
    private func editBookmarks(_ label: String, select: [Int]?, _ change: @escaping @Sendable ([Bookmark]) throws -> [Bookmark]) async -> Bool {
        let ok = await editor.run(label, contentOnly: true) { d, pw in
            try Bookmarks.setOutline(d, pw, try change(try Bookmarks.read(d, pw)))
        }
        if ok, let select {
            sidebar.show(1)
            sidebar.selectBookmark(select)
        }
        return ok
    }

    /// Adds a bookmark to `page` (from `top`, page space) after the bookmark at `after` (else at the end).
    @discardableResult
    func addBookmark(title: String, page: Int, top: Double?, after: [Int]?) async -> Bool {
        let count = readBookmarks().count
        let path: [Int] = after.map { Array($0.dropLast()) + [$0[$0.count - 1] + 1] } ?? [count]
        let bookmark = Bookmark(title, page, top: top)
        return await editBookmarks("Add bookmark “\(Self.short(title))”", select: path) { tree in
            try BookmarkTree.insert(tree, Array(path.dropLast()), path[path.count - 1], bookmark)
        }
    }

    @discardableResult
    func renameBookmark(_ path: [Int], to title: String) async -> Bool {
        await editBookmarks("Rename bookmark to “\(Self.short(title))”", select: path) { tree in
            try BookmarkTree.replace(tree, path) { b in
                var b = b
                b.title = title
                return b
            }
        }
    }

    @discardableResult
    func deleteBookmark(_ path: [Int]) async -> Bool {
        guard let b = try? BookmarkTree.at(readBookmarks(), path) else { return false }
        let inside = b.children.reduce(0) { $0 + 1 + Self.descendants($1) }
        let label = inside == 0 ? "Delete bookmark “\(Self.short(b.title))”" : "Delete bookmark “\(Self.short(b.title))” and \(inside) inside it"
        return await editBookmarks(label, select: nil) { tree in try BookmarkTree.remove(tree, path) }
    }

    /// Moves the bookmark at `from` to child `index` of `parent` (indexes as before the move).
    @discardableResult
    func moveBookmark(_ from: [Int], parent: [Int], index: Int) async -> Bool {
        guard let b = try? BookmarkTree.at(readBookmarks(), from) else { return false }
        let oldParent = Array(from.dropLast())
        if parent == oldParent && (index == from[from.count - 1] || index == from[from.count - 1] + 1) { return false } // stays put
        return await editBookmarks("Move bookmark “\(Self.short(b.title))”", select: nil) { tree in
            try BookmarkTree.move(tree, from, parent, index)
        }
    }

    private static func descendants(_ b: Bookmark) -> Int { b.children.reduce(0) { $0 + 1 + descendants($1) } }
}
