namespace InkvoltPrint.Core.Suite;

/// <summary>
/// Inkvolt Print's sidebar (the printer list, Add a printer, Settings, Help) and when it folds away, as Windows Settings
/// folds its navigation pane: the window's content is scaled by Windows' Text size, so at 150 % a 1180-DIP window has
/// room for 787 DIPs of it, and a 272-DIP sidebar would take a third. Below <see cref="Width"/> +
/// <see cref="MainMin"/> the sidebar becomes a Printers button that opens it over the page. Never at 100 % (the window's
/// minimum width is 860).
/// </summary>
public static class NavPane
{
    /// <summary>The sidebar's width, in the window's own (scaled) units.</summary>
    public const double Width = 272;

    /// <summary>The least room the printer's page needs beside the sidebar.</summary>
    public const double MainMin = 580;

    /// <summary>Whether the sidebar folds in a window content <paramref name="width"/> wide (scaled units).</summary>
    public static bool Folds(double width) => width > 0 && width < Width + MainMin;
}
