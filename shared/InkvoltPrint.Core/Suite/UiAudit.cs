namespace InkvoltPrint.Core.Suite;

/// <summary>
/// One interactive control as the UI audit sees it (the dev aids collect them from the visual tree: Inkvolt PDF's
/// <c>a11yaudit</c> step, Inkvolt Print's <c>--a11y-audit</c>).
/// </summary>
/// <param name="Kind">The control's type name (Button, TextBox…).</param>
/// <param name="Name">What a screen reader would say: the UI Automation name.</param>
/// <param name="Width">Its size in device-independent pixels.</param>
/// <param name="Where">Where it is: the named ancestors, outermost first ("DocCommands › FindBar").</param>
/// <param name="IsInline">True for a link inside running text, which may be as small as the text (WCAG 2.5.8's inline exception).</param>
public sealed record UiControl(string Kind, string? Name, double Width, double Height, string Where, bool IsInline = false);

/// <summary>
/// The rules the two apps' UI audits check on every visible control: a name a screen reader can say (WCAG 4.1.2,
/// Windows accessibility guidance) and a pointer target of at least 24 × 24 (WCAG 2.2 SC 2.5.8, Level AA). Pure, so
/// it is tested here; the apps only collect the controls.
/// </summary>
public static class UiAudit
{
    /// <summary>WCAG 2.2 SC 2.5.8 Target Size (Minimum): 24 by 24 CSS pixels.</summary>
    public const double MinTarget = 24;

    /// <summary>
    /// True when a name says nothing: empty, or only icon-font glyphs (Segoe Fluent Icons lives in the Private Use
    /// Area, so a button whose content is its glyph has a "name" a screen reader reads as nothing or as a code point).
    /// </summary>
    public static bool IsUnnamed(string? name)
    {
        if (string.IsNullOrWhiteSpace(name)) return true;
        foreach (var c in name)
        {
            if (char.IsWhiteSpace(c) || char.IsPunctuation(c) || char.IsSymbol(c)) continue;
            if (c is >= '' and <= '') continue; // Private Use Area: icon fonts
            return false;
        }
        return true;
    }

    /// <summary>True when the control is a pointer target under 24 × 24 and not inline text.</summary>
    public static bool IsSmallTarget(UiControl c) =>
        !c.IsInline && c.Width > 0 && c.Height > 0 && (c.Width < MinTarget - 0.5 || c.Height < MinTarget - 0.5);

    /// <summary>One line per problem, in the order given; empty when everything passes.</summary>
    public static IReadOnlyList<string> Findings(IEnumerable<UiControl> controls)
    {
        var lines = new List<string>();
        foreach (var c in controls)
        {
            if (IsUnnamed(c.Name)) lines.Add($"No accessible name: {c.Kind} at {c.Where} ({c.Width:0}×{c.Height:0})");
            if (IsSmallTarget(c)) lines.Add($"Small target: {c.Kind} '{c.Name}' is {c.Width:0}×{c.Height:0} at {c.Where} (needs {MinTarget}×{MinTarget})");
        }
        return lines;
    }
}
