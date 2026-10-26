import Foundation

/// Folders the user chose once (a scan preset's), remembered across launches as app-scoped security bookmarks
/// (`com.apple.security.files.bookmarks.app-scope`): the sandbox lets the app write there again without asking.
public enum FolderBookmarks {
    public static func make(_ folder: URL) -> Data? {
        try? folder.bookmarkData(options: [.withSecurityScope], includingResourceValuesForKeys: nil, relativeTo: nil)
    }

    /// The folder, and a fresh bookmark when macOS says the old one is stale (moved or renamed); nil when it's gone.
    public static func resolve(_ bookmark: Data) -> (url: URL, renewed: Data?)? {
        var stale = false
        guard let url = try? URL(resolvingBookmarkData: bookmark, options: [.withSecurityScope], relativeTo: nil, bookmarkDataIsStale: &stale)
        else { return nil }
        return (url, stale ? make(url) : nil)
    }
}
