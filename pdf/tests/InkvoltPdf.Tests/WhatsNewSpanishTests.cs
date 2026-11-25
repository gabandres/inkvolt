using System.Globalization;
using InkvoltPrint.Core.Suite;

namespace InkvoltPdf.Tests;

/// <summary>
/// What's New in Spanish (pdf/WHATS-NEW.es.md): the same headings in the same order as WHATS-NEW.md and one line for each English
/// line, so a line added in English and not in Spanish fails here; and the app shows it when its interface is Spanish
/// (<see cref="ReleaseNotes.For"/>, tested with Inkvolt Print's notes in InkvoltPrint.Tests).
/// </summary>
public class WhatsNewSpanishTests
{
    private static string Read(string name) => File.ReadAllText(Path.Combine(AppContext.BaseDirectory, "WhatsNew", name));

    /// <summary>Each "## " heading with how many "- " lines follow it.</summary>
    private static List<(string Heading, int Lines)> Outline(string markdown)
    {
        var outline = new List<(string, int)>();
        foreach (var line in markdown.ReplaceLineEndings("\n").Split('\n'))
        {
            if (line.StartsWith("## ", StringComparison.Ordinal)) outline.Add((line[3..].Trim(), 0));
            else if (line.StartsWith("- ", StringComparison.Ordinal) && outline.Count > 0) outline[^1] = (outline[^1].Item1, outline[^1].Item2 + 1);
        }
        return outline;
    }

    [Fact]
    public void Every_heading_and_line_has_its_spanish()
    {
        var english = Outline(Read("WHATS-NEW.md"));
        var spanish = Outline(Read("WHATS-NEW.es.md"));

        Assert.Equal(english, spanish);
        Assert.Contains(("Next", english[0].Lines), spanish);
    }

    [Fact]
    public void Every_spanish_line_is_translated()
    {
        var english = ReleaseNotes.Parse(Read("WHATS-NEW.md")).SelectMany(n => n.Items).ToHashSet();
        var spanish = ReleaseNotes.Parse(Read("WHATS-NEW.es.md")).SelectMany(n => n.Items).ToList();

        Assert.All(spanish, line => Assert.DoesNotContain(line, english));
        Assert.All(spanish, line => Assert.True(line.Length > 20, line));
    }

    [Fact]
    public void Every_heading_and_line_has_its_portuguese()
    {
        var english = Outline(Read("WHATS-NEW.md"));
        var portuguese = Outline(Read("WHATS-NEW.pt-BR.md"));

        Assert.Equal(english, portuguese);
        Assert.Contains(("Next", english[0].Lines), portuguese);
    }

    [Fact]
    public void Every_portuguese_line_is_translated()
    {
        var english = ReleaseNotes.Parse(Read("WHATS-NEW.md")).SelectMany(n => n.Items).ToHashSet();
        var portuguese = ReleaseNotes.Parse(Read("WHATS-NEW.pt-BR.md")).SelectMany(n => n.Items).ToList();

        Assert.All(portuguese, line => Assert.DoesNotContain(line, english));
        Assert.All(portuguese, line => Assert.True(line.Length > 20, line));
    }

    [Fact]
    public void The_real_spanish_notes_are_shown_in_spanish()
    {
        var notes = ReleaseNotes.For(Read("WHATS-NEW.md"), Read("WHATS-NEW.es.md"), new CultureInfo("es-PR"));

        Assert.StartsWith("Inkvolt PDF habla español", notes.Single(n => n.Version == new Version(1, 7, 0)).Items[0]);
    }
}
