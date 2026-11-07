import Foundation

/// JSONSerialization recurses without a limit: a few kilobytes of {"a":{"a":... from a server, a preset or a hand-off file
/// would run the thread out of stack and stop the app. So it reads only what nests within the depth Windows'
/// System.Text.Json allows by default; no answer, preset or file nests anywhere near it.
///
/// The count reads JSON5 too (`.json5Allowed`: batch presets, form data files), so nothing JSON5 allows can hide brackets
/// from it: a ' string as well as a " one, // and /* */ comments; and it never goes below 0 (a ] with nothing open,
/// which JSONSerialization refuses anyway, can't pay for nesting after it).
public enum JsonNesting {
    public static let limit = 64

    /// Whether `json` nests no deeper than `limit` (brackets in strings and comments not counted).
    public static func isSafe(_ json: Data) -> Bool {
        let quote: UInt8 = 0x22, apostrophe: UInt8 = 0x27, backslash: UInt8 = 0x5C, slash: UInt8 = 0x2F, star: UInt8 = 0x2A
        let newline: UInt8 = 0x0A, ret: UInt8 = 0x0D
        var depth = 0
        var string: UInt8 = 0 // the quote that opened the string being read; 0 outside one
        var escaped = false
        var lineComment = false, blockComment = false
        var previous: UInt8 = 0 // the byte before, when it may start or end a comment with this one; else 0
        for b in json {
            var next = b
            if string != 0 {
                if escaped {
                    escaped = false
                } else if b == backslash {
                    escaped = true
                } else if b == string {
                    string = 0
                }
            } else if lineComment {
                if b == newline || b == ret { lineComment = false }
            } else if blockComment {
                if b == slash && previous == star {
                    blockComment = false
                    next = 0 // "*/*" doesn't open another
                }
            } else if b == slash && previous == slash {
                lineComment = true
            } else if b == star && previous == slash {
                blockComment = true
                next = 0 // "/*/" doesn't close it
            } else if b == quote || b == apostrophe {
                string = b
            } else if b == 0x5B || b == 0x7B {
                depth += 1
                if depth > limit { return false }
            } else if b == 0x5D || b == 0x7D {
                depth = max(depth - 1, 0)
            }
            previous = next
        }
        return true
    }
}
