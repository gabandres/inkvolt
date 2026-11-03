using System.Text.RegularExpressions;
using System.Xml.Linq;

namespace InkvoltPrint.Tests;

/// <summary>
/// Every word Inkvolt Print's XAML shows comes from Strings.resx (<c>{x:Static loc:Strings.Key}</c>), so the Spanish
/// interface has no English left in it: no literal text in the attributes people see or hear, in a setter of one, or
/// between tags. Symbols, icons (Segoe Fluent Icons' private-use glyphs) and numbers aren't words.
/// </summary>
public partial class XamlTextTests
{
    /// <summary>The properties a person sees or a screen reader says.</summary>
    private static readonly HashSet<string> Shown =
    [
        "Text", "Content", "Header", "ToolTip", "Title", "AutomationProperties.Name", "AutomationProperties.HelpText",
        "AutomationProperties.ItemStatus", "Placeholder.Text", "PlaceholderText", "InputGestureText", "Description",
    ];

    /// <summary>Text that is the same in every language: keyboard shortcuts.</summary>
    private static readonly Regex Allowed = AllowedPattern();

    [Fact]
    public void Xaml_HasNoLiteralText()
    {
        var folder = Path.Combine(LocalizationTests.Root(), "print", "src", "InkvoltPrint.App");
        var files = Directory.EnumerateFiles(folder, "*.xaml", SearchOption.AllDirectories)
            .Where(f => !f.Contains($"{Path.DirectorySeparatorChar}obj{Path.DirectorySeparatorChar}")
                        && !f.Contains($"{Path.DirectorySeparatorChar}bin{Path.DirectorySeparatorChar}"))
            .ToList();
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
                    var property = PropertyName(attribute);
                    if (Shown.Contains(property) && IsWords(attribute.Value)) found.Add($"{name}:{line} {property}=\"{attribute.Value}\"");
                }
                // <Setter Property="Text" Value="…" />
                if (element.Name.LocalName == "Setter" && element.Attribute("Property") is { } p && Shown.Contains(Unqualified(p.Value))
                    && element.Attribute("Value") is { } v && IsWords(v.Value))
                    found.Add($"{name}:{line} Setter {p.Value}=\"{v.Value}\"");
                // <TextBlock>words</TextBlock>, <Run>words</Run>…
                foreach (var text in element.Nodes().OfType<XText>())
                    if (IsWords(text.Value.Trim())) found.Add($"{name}:{line} <{element.Name.LocalName}>{text.Value.Trim()}");
            }
        }
        Assert.True(found.Count == 0, $"{found.Count} literal texts in XAML (use {{x:Static loc:Strings.Key}}):\n" + string.Join("\n", found));
    }

    [Theory]
    [InlineData("Close", true)]
    [InlineData("Scan to PDF…", true)]
    [InlineData("{x:Static loc:Strings.Common_Close}", false)]
    [InlineData("{Binding Name}", false)]
    [InlineData("", false)] // a Segoe Fluent Icons glyph
    [InlineData("×", false)]
    [InlineData("100 %", false)]
    [InlineData("—", false)]
    [InlineData("Ctrl+P", false)]
    [InlineData("Ctrl+Shift+F5", false)]
    [InlineData("", false)]
    public void Words_AreToldFromSymbols(string value, bool words) => Assert.Equal(words, IsWords(value));

    private static bool IsWords(string value) =>
        value.Length > 0 && !value.StartsWith('{') && value.Any(char.IsLetter) && !Allowed.IsMatch(value);

    /// <summary>"AutomationProperties.Name", "Placeholder.Text" (local:Placeholder.Text), "Text".</summary>
    private static string PropertyName(XAttribute attribute) => Unqualified(attribute.Name.LocalName);

    private static string Unqualified(string name) => name.Contains(':') ? name[(name.IndexOf(':') + 1)..] : name;

    [GeneratedRegex(@"^((Ctrl|Shift|Alt|Win)\+)+(\w|F\d{1,2}|Del|Delete|Enter|Esc|Tab|Space|Home|End|PgUp|PgDn|Up|Down|Left|Right|Plus|Minus|[-+=,./])$")]
    private static partial Regex AllowedPattern();
}
