using InkvoltPdf.Core;
using MuPDFCore;

namespace InkvoltPdf.Tests;

/// <summary>Links from Addresses (roadmap 4.15, <see cref="AddressLinks"/>).</summary>
public class AddressLinksTests
{
    private static List<string> Found(string text) => [.. AddressLinks.Matches(text).Select(m => text.Substring(m.Start, m.Length))];

    [Fact]
    public void WebAndEmailAddressesAreFoundWithoutTheSentencesPunctuation()
    {
        Assert.Equal(["https://example.com/help"], Found("Visit https://example.com/help."));
        Assert.Equal(["www.example.org"], Found("See www.example.org, or call."));
        Assert.Equal(["billing@example.com"], Found("Write to billing@example.com."));
        Assert.Equal(["http://en.wikipedia.org/wiki/PDF_(format)"], Found("(see http://en.wikipedia.org/wiki/PDF_(format))"));
        Assert.Equal(["https://example.com/a?b=1&c=2#top"], Found("\"https://example.com/a?b=1&c=2#top\""));
        Assert.Equal(["josé@correo.es", "https://bücher.example/straße"], Found("josé@correo.es y https://bücher.example/straße;"));
        Assert.Equal(["first.last+tag@sub.example.co.uk"], Found("mailto:first.last+tag@sub.example.co.uk"));
    }

    [Fact]
    public void WhatOnlyLooksLikeAnAddressIsLeftAlone()
    {
        Assert.Empty(Found("a@b"));                         // no domain
        Assert.Empty(Found("user@localhost"));
        Assert.Empty(Found("x.@example.com and a..b@example.com"));
        Assert.Empty(Found("www. and https:// alone"));
        Assert.Empty(Found("version 1.2.3 and file.txt"));  // bare names aren't taken for addresses
        Assert.Empty(Found("ftp://files.example.com"));    // only web and email addresses
        Assert.Empty(Found("x" + new string('a', 5000) + "@"));
        Assert.Equal(["www.example.com"], Found("go to www.example.com"));
    }

    private static byte[] Pdf() => Core2Pdf.Build(
    [
        "<< /Type /Catalog /Pages 2 0 R >>",
        "<< /Type /Pages /Kids [3 0 R] /Count 1 >>",
        "<< /Type /Page /Parent 2 0 R /MediaBox [0 0 612 792] /Contents 4 0 R /Resources << /Font << /F1 5 0 R >> >> >>",
        Core2Pdf.Stream("BT /F1 11 Tf 72 700 Td (Visit https://example.com/help or write to billing@example.com today.) Tj 0 -20 Td (Our site www.example.org has more.) Tj ET"),
        "<< /Type /Font /Subtype /Type1 /BaseFont /Helvetica /Encoding /WinAnsiEncoding >>",
    ]);

    [Fact]
    public void EachAddressBecomesALinkOverItsTextInOneChange()
    {
        var pdf = Pdf();
        IReadOnlyList<FoundAddress> found;
        using (var engine = PdfEngine.Open(pdf, InputFileTypes.PDF, null)) found = AddressLinks.Find(engine);
        Assert.Equal(["https://example.com/help", "mailto:billing@example.com", "https://www.example.org/"], found.Select(f => f.Uri));
        Assert.Equal("billing@example.com", found[1].Text);
        Assert.All(found, f => Assert.InRange(f.Boxes.Single().Y, 70, 120)); // top of the page, page space

        var linked = AddressLinks.Apply(pdf, null, found);
        var links = Links.Read(linked, null);
        Assert.Equal(found.Select(f => f.Uri), links.Select(l => l.Uri));
        for (var i = 0; i < found.Count; i++) Assert.Equal(found[i].Boxes[0].CenterX, links[i].Rect.CenterX, 1.0);
        using var after = PdfEngine.Open(linked, InputFileTypes.PDF, null);
        Assert.Equal(3, after.GetLinks(0).Count);

        // Run again: every address is linked already, nothing is found.
        using var again = PdfEngine.Open(linked, InputFileTypes.PDF, null);
        Assert.Empty(AddressLinks.Find(again));
    }

    [Fact]
    public void AnAddressAlreadyLinkedIsSkippedAndTheChosenOnesAreKept()
    {
        // A link the document has over the email address (its own target).
        var pdf = Core2Pdf.Build(
        [
            "<< /Type /Catalog /Pages 2 0 R >>",
            "<< /Type /Pages /Kids [3 0 R] /Count 1 >>",
            "<< /Type /Page /Parent 2 0 R /MediaBox [0 0 612 792] /Contents 4 0 R /Resources << /Font << /F1 5 0 R >> >> /Annots [6 0 R] >>",
            Core2Pdf.Stream("BT /F1 11 Tf 72 700 Td (Visit https://example.com/help or write to billing@example.com today.) Tj 0 -20 Td (Our site www.example.org has more.) Tj ET"),
            "<< /Type /Font /Subtype /Type1 /BaseFont /Helvetica /Encoding /WinAnsiEncoding >>",
            "<< /Type /Annot /Subtype /Link /Rect [250 695 400 715] /A << /S /URI /URI (mailto:sales@example.com) >> >>",
        ]);
        using var engine = PdfEngine.Open(pdf, InputFileTypes.PDF, null);
        var found = AddressLinks.Find(engine);
        Assert.Equal(["https://example.com/help", "https://www.example.org/"], found.Select(f => f.Uri));
        var links = Links.Read(AddressLinks.Apply(pdf, null, [found[1]]), null);
        Assert.Equal(["mailto:sales@example.com", "https://www.example.org/"], links.Select(l => l.Uri));
    }

    [Fact]
    public void FindingStopsWhenCancelled()
    {
        using var engine = PdfEngine.Open(Pdf(), InputFileTypes.PDF, null);
        using var cts = new CancellationTokenSource();
        cts.Cancel();
        Assert.Throws<OperationCanceledException>(() => AddressLinks.Find(engine, cancel: cts.Token));
    }
}
