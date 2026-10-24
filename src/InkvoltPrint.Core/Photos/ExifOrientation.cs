namespace InkvoltPrint.Core.Photos;

/// <summary>
/// The EXIF Orientation tag (274): how a camera's stored pixels must be mirrored and turned to look right. Mirror first
/// (left-right), then turn clockwise by quarter turns, as ExifTool describes each value.
/// </summary>
public static class ExifOrientation
{
    /// <summary>1 as stored, 2 mirrored, 3 half turn, 4 mirrored + half turn, 5 mirrored + 270°, 6 90°, 7 mirrored + 90°, 8 270°; anything else as stored.</summary>
    public static (int QuarterTurns, bool Mirror) Transform(int orientation) => orientation switch
    {
        2 => (0, true),
        3 => (2, false),
        4 => (2, true),
        5 => (3, true),
        6 => (1, false),
        7 => (1, true),
        8 => (3, false),
        _ => (0, false),
    };

    /// <summary>All quarter turns clockwise for a photo: its EXIF turn plus the user's (negative: to the left), 0-3.</summary>
    public static int Turns(int orientation, int userTurns) => ((Transform(orientation).QuarterTurns + userTurns) % 4 + 4) % 4;

    /// <summary>A <paramref name="width"/> × <paramref name="height"/> stored image's size as it looks, after EXIF and the user's turns.</summary>
    public static (int Width, int Height) Oriented(int width, int height, int orientation, int userTurns) =>
        Turns(orientation, userTurns) % 2 == 1 ? (height, width) : (width, height);
}
