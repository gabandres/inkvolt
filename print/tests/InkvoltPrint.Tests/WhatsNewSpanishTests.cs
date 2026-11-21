using System.Globalization;
using InkvoltPrint.Core.Suite;

namespace InkvoltPrint.Tests;

/// <summary>
/// What's New in Spanish (print/WHATS-NEW.es.md): the same headings in the same order as WHATS-NEW.md and one line for each English
/// line, so a line added in English and not in Spanish fails here; and the app's notes follow the interface language
/// (<see cref="ReleaseNotes.For"/>).
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

    [Theory]
    [InlineData("es", "Nuevo")]
    [InlineData("es-PR", "Nuevo")]
    [InlineData("en", "New")]
    [InlineData("en-US", "New")]
    public void The_notes_follow_the_interface_language(string culture, string first)
    {
        const string english = "## 1.1.0\n- New\n";
        const string spanish = "## 1.1.0\n- Nuevo\n";

        Assert.Equal(first, ReleaseNotes.For(english, spanish, new CultureInfo(culture))[0].Items[0]);
    }

    [Theory]
    [InlineData(null)]
    [InlineData("")]
    [InlineData("## Next\n- Nada todavía\n")]
    public void Spanish_notes_missing_or_empty_fall_back_to_english(string? spanish) =>
        Assert.Equal("New", ReleaseNotes.For("## 1.1.0\n- New\n", spanish, new CultureInfo("es"))[0].Items[0]);

    [Fact]
    public void The_real_spanish_notes_are_shown_in_spanish()
    {
        var notes = ReleaseNotes.For(Read("WHATS-NEW.md"), Read("WHATS-NEW.es.md"), new CultureInfo("es"));

        Assert.StartsWith("Inkvolt Print habla español", notes.Single(n => n.Version == new Version(1, 3, 0)).Items[2]);
    }
}
