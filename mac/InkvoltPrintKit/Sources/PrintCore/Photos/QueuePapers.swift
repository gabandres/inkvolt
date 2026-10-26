import Foundation

/// A paper size a print queue offers (CUPS's media list, `cupsGetDestMediaByIndex`): its name, size and the margins the
/// printer keeps, in inches. Margins all zero: borderless.
public struct QueueMedia: Equatable, Sendable {
    public var name: String
    public var width: Double, height: Double
    public var left: Double, top: Double, right: Double, bottom: Double

    public init(name: String, width: Double, height: Double, left: Double, top: Double, right: Double, bottom: Double) {
        self.name = name
        self.width = width
        self.height = height
        self.left = left
        self.top = top
        self.right = right
        self.bottom = bottom
    }

    public var isBorderless: Bool { left <= 0.001 && top <= 0.001 && right <= 0.001 && bottom <= 0.001 }
}

/// A paper Print Photos lays out on: a size with its printable area, and the same size's borderless variant when the queue
/// has one (the Windows app's paper choices with `PageBorderlessCapability`).
public struct PhotoPaperChoice: Equatable, Sendable, Identifiable {
    public var label: String
    public var sheet: SheetPaper
    /// The CUPS media name to ask for (the bordered one).
    public var media: String
    public var borderless: QueueMedia?

    public var id: String { media }

    public init(label: String, sheet: SheetPaper, media: String, borderless: QueueMedia? = nil) {
        self.label = label
        self.sheet = sheet
        self.media = media
        self.borderless = borderless
    }

    /// The sheet to lay out on: edge to edge when borderless is asked for and offered.
    public func sheet(borderless wanted: Bool) -> SheetPaper {
        guard wanted, let b = borderless else { return sheet }
        return SheetPaper(b.width, b.height, 0, 0, 0, 0)
    }
}

public enum QueuePapers {
    /// The queue's papers as choices, one per size (sizes within 0.04 in are the same paper): the bordered variant's
    /// printable area, with the borderless variant beside it. A size offered only borderless still gets a choice. Sorted
    /// as the queue lists them.
    public static func photoChoices(_ media: [QueueMedia]) -> [PhotoPaperChoice] {
        var choices: [PhotoPaperChoice] = []
        for m in media where m.width > 0 && m.height > 0 {
            if let i = choices.firstIndex(where: { same($0.sheet.width, $0.sheet.height, m.width, m.height) }) {
                if m.isBorderless {
                    if choices[i].borderless == nil { choices[i].borderless = m }
                } else if choices[i].sheet.left == 0 && choices[i].sheet.top == 0 && choices[i].borderless != nil {
                    // Only the borderless variant was seen so far: the bordered one takes the main place.
                    choices[i].sheet = SheetPaper(m.width, m.height, m.left, m.top, m.right, m.bottom)
                    choices[i].media = m.name
                }
                continue
            }
            let sheet = SheetPaper(m.width, m.height, m.left, m.top, m.right, m.bottom)
            choices.append(PhotoPaperChoice(label: PhotoPaperText.paper(m.name, m.width, m.height), sheet: sheet, media: m.name,
                                            borderless: m.isBorderless ? m : nil))
        }
        return choices
    }

    /// The choice to start with: the region's usual paper (A4 or Letter), else the queue's first.
    public static func preferred(_ choices: [PhotoPaperChoice], metric: Bool) -> PhotoPaperChoice? {
        let usual: (Double, Double) = metric ? (210 / 25.4, 297 / 25.4) : (8.5, 11)
        return choices.first { same($0.sheet.width, $0.sheet.height, usual.0, usual.1) } ?? choices.first
    }

    private static func same(_ w1: Double, _ h1: Double, _ w2: Double, _ h2: Double) -> Bool {
        let (a1, b1) = (min(w1, h1), max(w1, h1)), (a2, b2) = (min(w2, h2), max(w2, h2))
        return abs(a1 - a2) < 0.04 && abs(b1 - b2) < 0.04
    }
}

extension PhotoLayout {
    /// The lowest resolution each photo prints at over `sheets` (nil for a photo not on any sheet), from its pixel size.
    public static func printDpi(_ sheets: [PhotoSheet], _ photos: [PhotoInput]) -> [Double?] {
        var lowest = [Double?](repeating: nil, count: photos.count)
        for sheet in sheets {
            for cell in sheet.cells where cell.photo < photos.count {
                let d = dpi(photos[cell.photo].width, photos[cell.photo].height, cell.image, turned: cell.turned)
                lowest[cell.photo] = min(lowest[cell.photo] ?? d, d)
            }
        }
        return lowest
    }
}
