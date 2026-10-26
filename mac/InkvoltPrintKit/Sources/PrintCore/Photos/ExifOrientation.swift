import Foundation

/// The EXIF Orientation tag (274): how a camera's stored pixels must be mirrored and turned to look right. Mirror first
/// (left-right), then turn clockwise by quarter turns, as ExifTool describes each value.
public enum ExifOrientation {
    /// 1 as stored, 2 mirrored, 3 half turn, 4 mirrored + half turn, 5 mirrored + 270°, 6 90°, 7 mirrored + 90°, 8 270°;
    /// anything else as stored.
    public static func transform(_ orientation: Int) -> (quarterTurns: Int, mirror: Bool) {
        switch orientation {
        case 2: (0, true)
        case 3: (2, false)
        case 4: (2, true)
        case 5: (3, true)
        case 6: (1, false)
        case 7: (1, true)
        case 8: (3, false)
        default: (0, false)
        }
    }

    /// All quarter turns clockwise for a photo: its EXIF turn plus the user's (negative: to the left), 0-3.
    public static func turns(_ orientation: Int, _ userTurns: Int) -> Int {
        ((transform(orientation).quarterTurns + userTurns % 4) % 4 + 4) % 4
    }

    /// A `width` × `height` stored image's size as it looks, after EXIF and the user's turns.
    public static func oriented(_ width: Int, _ height: Int, _ orientation: Int, _ userTurns: Int) -> (width: Int, height: Int) {
        turns(orientation, userTurns) % 2 == 1 ? (height, width) : (width, height)
    }
}
