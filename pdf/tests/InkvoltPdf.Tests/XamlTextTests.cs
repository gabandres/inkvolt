using System.Text.RegularExpressions;
using System.Xml.Linq;

namespace InkvoltPdf.Tests;

/// <summary>
/// Every word Inkvolt PDF's XAML shows comes from Strings.resx (<c>{x:Static loc:Strings.Key}</c>), so the Spanish
/// interface has no English left in it: no literal text in the attributes people see or hear, in a setter of one, or
/// between tags; and, best effort, none in the menus, buttons and dialogs the code builds. Symbols, icons (Segoe Fluent
/// Icons' private-use glyphs), numbers and keyboard shortcuts aren't words.
/// </summary>
public partial class XamlTextTests
{
    /// <summary>The properties a person sees or a screen reader says.</summary>
    private static readonly HashSet<string> Shown =
    [
        "Text", "Content", "Header", "ToolTip", "Title", "AutomationProperties.Name", "AutomationProperties.HelpText",
        "AutomationProperties.ItemStatus", "Placeholder.Text", "PlaceholderText", "InputGestureText", "Description",
    ];

    private static string AppFolder => Path.Combine(LocalizationTests.Root(), "pdf", "src", "InkvoltPdf.App");

    private static IEnumerable<string> Sources(string pattern) =>
        Directory.EnumerateFiles(AppFolder, pattern, SearchOption.AllDirectories)
            .Where(f => !f.Contains($"{Path.DirectorySeparatorChar}obj{Path.DirectorySeparatorChar}")
                        && !f.Contains($"{Path.DirectorySeparatorChar}bin{Path.DirectorySeparatorChar}"));

    [Fact]
    public void Xaml_HasNoLiteralText()
    {
        var files = Sources("*.xaml").ToList();
        Assert.NotEmpty(files);
        var found = new List<string>();
        foreach (var file in files)
        {
            var name = Path.GetFileName(file);
            foreach (var element in XDocument.Load(file, LoadOptions.SetLineInfo).Descendants())
            {
                var line = ((System.Xml.IXmlLineInfo)element).LineNumber;
                foreach (var attribute in element.Attributes())
                {
                    var property = Unqualified(attribute.Name.LocalName);
                    if (Shown.Contains(property) && IsWords(attribute.Value)) found.Add($"{name}:{line} {property}=\"{attribute.Value}\"");
                }
                if (element.Name.LocalName == "Setter" && element.Attribute("Property") is { } p && Shown.Contains(Unqualified(p.Value))
                    && element.Attribute("Value") is { } v && IsWords(v.Value))
                    found.Add($"{name}:{line} Setter {p.Value}=\"{v.Value}\"");
                // <FontFamily>Segoe UI Variable Text</FontFamily>: a font's name, not words
                if (element.Name.LocalName == "FontFamily") continue;
                foreach (var text in element.Nodes().OfType<XText>())
                    if (IsWords(text.Value.Trim())) found.Add($"{name}:{line} <{element.Name.LocalName}>{text.Value.Trim()}");
            }
        }
        Assert.True(found.Count == 0, $"{found.Count} literal texts in XAML (use {{x:Static loc:Strings.Key}}):\n" + string.Join("\n", found));
    }

    /// <summary>
    /// Best effort for what the code builds: a visible property set to a literal (<c>Header = "Rotate"</c>,
    /// <c>ToolTip = $"…"</c>), an accessible name set to one, or a literal handed to the menu and dialog helpers
    /// (<c>Item("…")</c>, <c>AddCheck("…")</c>, <c>ShowStatus("…")</c>…). The dev aids (DevScript, UiInspection) and the
    /// command line stay English, and so does a line that says it is the same in every language (a comment
    /// <c>// in every language</c>: a file name, a version).
    /// </summary>
    [Fact]
    public void Code_BuildsNoMenuOrDialogFromLiteralText()
    {
        string[] english = ["DevScript.cs", "CommandLine.cs", "UiInspection.cs", "Program.cs"];
        var found = new List<string>();
        foreach (var file in Sources("*.cs").Where(f => !english.Contains(Path.GetFileName(f))))
        {
            var lines = File.ReadAllLines(file);
            for (var i = 0; i < lines.Length; i++)
            {
                var line = lines[i];
                if (line.TrimStart().StartsWith("//", StringComparison.Ordinal) || line.Contains("Log.Write", StringComparison.Ordinal)
                    || line.Contains("// in every language", StringComparison.Ordinal)) continue;
                foreach (Match m in CodeLiteral().Matches(line))
                    if (IsWords(Escapes().Replace(m.Groups["text"].Value, ""))) found.Add($"{Path.GetFileName(file)}:{i + 1} {m.Value.Trim()}");
            }
        }
        Assert.True(found.Count == 0, $"{found.Count} literal texts in code-built menus and dialogs (use Strings):\n" + string.Join("\n", found));
    }

    [Theory]
    [InlineData("Close", true)]
    [InlineData("Scan to PDF…", true)]
    [InlineData("{x:Static loc:Strings.Common_Close}", false)]
    [InlineData("{Binding Name}", false)]
    [InlineData("", false)]
    [InlineData("×", false)]
    [InlineData("100 %", false)]
    [InlineData("—", false)]
    [InlineData("Ctrl+P", false)]
    [InlineData("Ctrl+Shift+F5", false)]
    [InlineData("PDF", false)] // a format's name is the same in every language
    public void Words_AreToldFromSymbols(string value, bool words) => Assert.Equal(words, IsWords(value));

    [Theory]
    [InlineData("""item.Header = "Rotate";""", true)]
    [InlineData("""new MenuItem { Header = $"Page {n}" }""", true)]
    [InlineData("""dlg.AddCheck("Keep recovery copies", true);""", true)]
    [InlineData("""ShowStatus("Saved");""", true)]
    [InlineData("""item.Header = Strings.Main_Rotate;""", false)]
    [InlineData("""AutomationProperties.SetName(box, "Find");""", true)]
    [InlineData("""Tag = "Rotate" """, false)]
    public void CodeLiterals_AreFound(string code, bool found) =>
        Assert.Equal(found, CodeLiteral().Matches(code).Any(m => IsWords(m.Groups["text"].Value)));

    /// <summary>Words, not a symbol, a number, a shortcut or a product or format name that reads the same in Spanish.</summary>
    private static bool IsWords(string value) =>
        value.Length > 0 && !value.StartsWith('{') && value.Count(char.IsLetter) >= 2 && !Allowed().IsMatch(value);

    /// <summary>A glyph written as an escape (""), not words.</summary>
    [GeneratedRegex(@"\\u[0-9A-Fa-f]{4}")]
    private static partial Regex Escapes();

    private static string Unqualified(string name) => name.Contains(':') ? name[(name.IndexOf(':') + 1)..] : name;

    [GeneratedRegex(@"^(((Ctrl|Shift|Alt|Win)\+)+(\w|F\d{1,2}|Del|Delete|Enter|Esc|Tab|Space|Home|End|PgUp|PgDn|Up|Down|Left|Right|Plus|Minus|[-+=,./])|PDF|OCR|PDF/A|Inkvolt PDF|Inkvolt Pro|Inkvolt Print|Word|Excel|PowerPoint|HTML|XFDF|FDF|CSV|JSON|TXT|Ollama|LM Studio|OK)$")]
    private static partial Regex Allowed();

    [GeneratedRegex("""(\b(Header|Content|ToolTip|Title|Text|Watermark|PlaceholderText)\s*=\s*\$?"(?<text>[^"]*)"|AutomationProperties\.Set(Name|HelpText)\([^,]+,\s*\$?"(?<text>[^"]*)"|\b(Item|AddCheck|AddChoice|AddNote|AddText|AddFooterButton|ShowStatus|Toast)\(\s*\$?"(?<text>[^"]*)")""")]
    private static partial Regex CodeLiteral();
}
