namespace InkvoltPdf.Core;

/// <summary>The Microsoft Office app that turns a file into a PDF.</summary>
public enum OfficeApp { Word, Excel, PowerPoint }

/// <summary>
/// Office files made into PDFs by the user's own Microsoft Office (Word, Excel or PowerPoint, through automation in the
/// app): which app opens which file, the open dialog's filter, names, and the files Office would stop to ask a password for.
/// </summary>
public static class OfficeFiles
{
    private static readonly string[] Word = [".docx", ".doc", ".docm", ".dotx", ".dot", ".rtf", ".odt"];
    private static readonly string[] Excel = [".xlsx", ".xls", ".xlsm", ".xlsb", ".ods"];
    private static readonly string[] PowerPoint = [".pptx", ".ppt", ".pptm", ".ppsx", ".pps", ".odp"];
    private static readonly string[] OpenXml = [".docx", ".docm", ".dotx", ".xlsx", ".xlsm", ".xlsb", ".pptx", ".pptm", ".ppsx"];

    public static IReadOnlyList<string> Extensions(OfficeApp app) => app switch
    {
        OfficeApp.Word => Word,
        OfficeApp.Excel => Excel,
        _ => PowerPoint,
    };

    /// <summary>The app for <paramref name="path"/> (by extension), or null when it isn't an Office file.</summary>
    public static OfficeApp? AppFor(string path)
    {
        var ext = Path.GetExtension(path);
        if (ext.Length == 0) return null;
        foreach (var app in Enum.GetValues<OfficeApp>())
            if (Extensions(app).Contains(ext, StringComparer.OrdinalIgnoreCase)) return app;
        return null;
    }

    public static string AppName(OfficeApp app) => app switch
    {
        OfficeApp.Word => "Microsoft Word",
        OfficeApp.Excel => "Microsoft Excel",
        _ => "Microsoft PowerPoint",
    };

    /// <summary>"*.docx;*.doc;…" for the apps given ("" for none).</summary>
    public static string FilterPattern(IEnumerable<OfficeApp> apps) => string.Join(";", apps.SelectMany(Extensions).Select(e => "*" + e));

    /// <summary>
    /// An Office Open XML file (normally a ZIP) stored as an OLE compound file: that is how Office saves one protected
    /// with a password (the package is encrypted inside). Office would stop and ask for the password.
    /// </summary>
    public static bool IsEncryptedOpenXml(ReadOnlySpan<byte> head, string path) =>
        OpenXml.Contains(Path.GetExtension(path), StringComparer.OrdinalIgnoreCase) && head.StartsWith((ReadOnlySpan<byte>)[0xD0, 0xCF, 0x11, 0xE0, 0xA1, 0xB1, 0x1A, 0xE1]);

    /// <summary>The PDF's name: the file's own name with .pdf.</summary>
    public static string PdfName(string path) => Path.GetFileNameWithoutExtension(path) + ".pdf";
}

public enum WebPaper { Letter, A4, Legal }

public enum WebMargins { None, Narrow, Normal, Wide }

/// <summary>How a web page is printed to PDF (WebView2's print settings, in inches).</summary>
public sealed record WebPdfOptions
{
    public WebPaper Paper { get; init; }
    public bool Landscape { get; init; }
    public WebMargins Margins { get; init; } = WebMargins.Normal;

    /// <summary>Background colors and pictures (off: the page prints like a browser's default, on white).</summary>
    public bool Backgrounds { get; init; } = true;

    /// <summary>The browser's header and footer: title, address, date and page numbers.</summary>
    public bool HeaderAndFooter { get; init; }

    public (double Width, double Height) PageInches
    {
        get
        {
            var (w, h) = Paper switch
            {
                WebPaper.A4 => (8.27, 11.69),
                WebPaper.Legal => (8.5, 14.0),
                _ => (8.5, 11.0),
            };
            return Landscape ? (h, w) : (w, h);
        }
    }

    public double MarginInches => Margins switch
    {
        WebMargins.None => 0,
        WebMargins.Narrow => 0.25,
        WebMargins.Wide => 1,
        _ => 0.4,
    };
}

/// <summary>Web pages and saved web files (HTML, MHT) made into PDFs with WebView2.</summary>
public static class WebFiles
{
    public static readonly IReadOnlyList<string> Extensions = [".html", ".htm", ".mht", ".mhtml"];

    public static bool IsWebFile(string path) => Extensions.Contains(Path.GetExtension(path), StringComparer.OrdinalIgnoreCase);

    /// <summary>
    /// A typed web address: http or https (https is added when no scheme is typed), with a host. Anything else (file,
    /// javascript, data, ftp addresses) is refused: local files are chosen with Browse.
    /// </summary>
    public static bool TryParseAddress(string text, out Uri? uri, out string? error)
    {
        uri = null;
        text = text.Trim();
        if (text.Length == 0)
        {
            error = "Type a web address, such as example.com.";
            return false;
        }
        var hasScheme = text.Contains("://", StringComparison.Ordinal) || text.StartsWith("javascript:", StringComparison.OrdinalIgnoreCase) ||
                        text.StartsWith("data:", StringComparison.OrdinalIgnoreCase) || text.StartsWith("file:", StringComparison.OrdinalIgnoreCase);
        if (!Uri.TryCreate(hasScheme ? text : "https://" + text, UriKind.Absolute, out var parsed))
        {
            error = "That isn't a web address.";
            return false;
        }
        if (parsed.Scheme != Uri.UriSchemeHttp && parsed.Scheme != Uri.UriSchemeHttps)
        {
            error = "Only web addresses (http or https) can be opened here. For a file on this PC, use Browse.";
            return false;
        }
        if (string.IsNullOrEmpty(parsed.Host))
        {
            error = "That web address has no site name.";
            return false;
        }
        uri = parsed;
        error = null;
        return true;
    }

    /// <summary>"example.com - story.pdf": the site, and the last part of the path when there is one.</summary>
    public static string PdfName(Uri uri)
    {
        var last = uri.AbsolutePath.TrimEnd('/').Split('/').LastOrDefault(s => s.Length > 0) ?? "";
        var invalid = Path.GetInvalidFileNameChars();
        last = new string([.. Uri.UnescapeDataString(last).Select(c => invalid.Contains(c) ? '_' : c)]);
        if (last.LastIndexOf('.') is > 0 and var dot && last.Length - dot <= 6) last = last[..dot]; // story.html: story
        var name = (last.Length > 0 ? $"{uri.Host} - {last}" : uri.Host).Trim();
        if (name.Length > 100) name = name[..100].TrimEnd();
        return name + ".pdf";
    }
}
