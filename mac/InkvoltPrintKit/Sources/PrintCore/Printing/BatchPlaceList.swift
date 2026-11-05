import Foundation

/// A file or folder the Batch Print window was given, by its path (as the user chose it, standardized), with its app-scoped
/// security bookmark (`PrintState.batchPlaces`).
public struct BatchPlace: Codable, Sendable, Equatable {
    public var path: String
    public var bookmark: Data

    public init(_ path: String, _ bookmark: Data) {
        self.path = path
        self.bookmark = bookmark
    }
}

/// The remembered places, kept by path: what the app adds and opens needs no bookmark resolved to find (Mac only: the
/// sandbox; the app's `BatchPlaces` makes, resolves and opens the bookmarks).
public enum BatchPlaceList {
    /// `places` with `given` remembered: each path once with its newest bookmark, newest last, at most `PrintState.maxBatchPlaces`.
    public static func remember(_ places: [BatchPlace], _ given: [BatchPlace]) -> [BatchPlace] {
        var kept = places
        for place in given {
            kept.removeAll { key($0.path) == key(place.path) }
            kept.append(place)
        }
        return Array(kept.suffix(PrintState.maxBatchPlaces))
    }

    /// The places that let the sandbox reach `paths`: a path's own, and each folder it is in. One path a place doesn't reach
    /// isn't reached through it ("/a/b" doesn't reach "/a/bc").
    public static func covering(_ places: [BatchPlace], _ paths: [String]) -> [BatchPlace] {
        let wanted = paths.map(key)
        return places.filter { place in
            let at = key(place.path)
            return wanted.contains { $0 == at || $0.hasPrefix(at == "/" ? at : at + "/") }
        }
    }

    /// `places` with the bookmark macOS renewed for `old` (a stale one: the place was moved or renamed), under the path it
    /// resolved to.
    public static func renewed(_ places: [BatchPlace], _ old: BatchPlace, to place: BatchPlace) -> [BatchPlace] {
        guard places.contains(old) else { return places }
        return places.compactMap { $0 == old ? place : key($0.path) == key(place.path) ? nil : $0 } // the path once
    }

    /// One place however its path is spelt: macOS's volumes are case-insensitive by default, and a folder may end in "/".
    static func key(_ path: String) -> String {
        var key = path.lowercased()
        while key.count > 1, key.hasSuffix("/") { key.removeLast() }
        return key
    }
}
