using System.Security.Cryptography;
using System.Text;
using InkvoltPdf.Core;
using PdfSharp.Pdf;
using PdfSharp.Pdf.IO;

namespace InkvoltPdf.Tests;

/// <summary>
/// The standard security handler as <see cref="UserPasswordEdits"/> uses it: which method and key each string and stream
/// is encrypted with (/StrF, /StmF, /EFF, /EncryptMetadata), and the handlers it refuses as the document opens.
/// </summary>
public class StandardCryptTests
{
    private static readonly byte[] Data = Encoding.ASCII.GetBytes("Some content of an object, long enough to tell.");

    /// <summary>A one-page document protected by PDFsharp (user password empty), opened with it.</summary>
    private static (PdfDocument Doc, byte[] Id0) Protected(string method)
    {
        using var plain = new PdfDocument();
        plain.AddPage();
        var h = plain.SecurityHandler;
        switch (method)
        {
            case "rc4-128": h.SetEncryptionToV2(128); break;
            case "aes-128": h.SetEncryptionToV4UsingAES(); break;
            case "aes-256": h.SetEncryptionToV5(); break;
            default: throw new ArgumentException(method);
        }
        plain.SecuritySettings.OwnerPassword = "own";
        using var ms = new MemoryStream();
        plain.Save(ms, false);
        var data = ms.ToArray();
        var id = Incremental.Tail(data)!.Id!;
        return (PdfObj.Read(data, null, PdfDocumentOpenMode.Import), Convert.FromHexString(id[2..id.IndexOf('>')]));
    }

    private static StandardCrypt? Crypt((PdfDocument Doc, byte[] Id0) p) => StandardCrypt.FromUserPassword(p.Doc.SecurityHandler, p.Id0, "");

    private static PdfDictionary Filter(string cfm) => new() { Elements = { ["/CFM"] = new PdfName("/" + cfm), ["/AuthEvent"] = new PdfName("/DocOpen") } };

    private static bool Plain(byte[] written) => written.AsSpan().SequenceEqual(Data);

    [Fact]
    public void EmbeddedFilesUseTheirOwnFilter()
    {
        // /EFF names a filter that leaves attachments plain: they are written plain, every other stream encrypted.
        var p = Protected("aes-256");
        var h = p.Doc.SecurityHandler;
        PdfObj.Dict(h.Elements["/CF"])!.Elements["/EFFCF"] = Filter("None");
        h.Elements["/EFF"] = new PdfName("/EFFCF");
        var crypt = Crypt(p)!;
        Assert.True(Plain(crypt.Encrypt(7, 0, Data, CryptTarget.EmbeddedFile)));
        Assert.False(Plain(crypt.Encrypt(7, 0, Data, CryptTarget.Stream)));
        Assert.False(Plain(crypt.Encrypt(7, 0, Data, CryptTarget.String)));

        // The other way round: streams plain (/StmF /Identity), attachments encrypted.
        h.Elements["/StmF"] = new PdfName("/Identity");
        h.Elements["/EFF"] = new PdfName("/StdCF");
        crypt = Crypt(p)!;
        Assert.False(Plain(crypt.Encrypt(7, 0, Data, CryptTarget.EmbeddedFile)));
        Assert.True(Plain(crypt.Encrypt(7, 0, Data, CryptTarget.Stream)));

        // Without /EFF, attachments are streams like the rest.
        h.Elements.Remove("/EFF");
        Assert.True(Plain(Crypt(p)!.Encrypt(7, 0, Data, CryptTarget.EmbeddedFile)));
    }

    [Fact]
    public void EncryptMetadataFalseLeavesOnlyTheDocumentsMetadataPlain()
    {
        var p = Protected("aes-256");
        p.Doc.SecurityHandler.Elements["/EncryptMetadata"] = new PdfBoolean(false);
        var crypt = Crypt(p)!;
        Assert.True(Plain(crypt.Encrypt(7, 0, Data, CryptTarget.DocumentMetadata)));
        Assert.False(Plain(crypt.Encrypt(7, 0, Data, CryptTarget.Stream))); // a page's or an image's /Type /Metadata stream too

        p.Doc.SecurityHandler.Elements.Remove("/EncryptMetadata");
        Assert.False(Plain(Crypt(p)!.Encrypt(7, 0, Data, CryptTarget.DocumentMetadata)));
    }

    [Fact]
    public void WhatEachStreamIsTargetedAsComesFromTheDocument()
    {
        // The catalog's /Metadata is the document's; a page's /Metadata stream isn't. An attachment is a stream an /EF
        // names (direct filespecs inside annotations too) or one typed /EmbeddedFile.
        using var doc = new PdfDocument();
        var page = doc.AddPage();
        PdfDictionary Stream(string type)
        {
            var d = new PdfDictionary(doc);
            if (type.Length > 0) d.Elements["/Type"] = new PdfName(type);
            d.CreateStream(Data);
            doc.Internals.AddObject(d);
            return d;
        }
        var docXmp = Stream("/Metadata");
        var pageXmp = Stream("/Metadata");
        var named = Stream("");
        var typed = Stream("/EmbeddedFile");
        var other = Stream("");
        doc.Internals.Catalog.Elements["/Metadata"] = docXmp.Reference;
        page.Elements["/Metadata"] = pageXmp.Reference;
        var annot = new PdfDictionary(doc);
        annot.Elements["/Subtype"] = new PdfName("/FileAttachment");
        annot.Elements["/FS"] = new PdfDictionary { Elements = { ["/Type"] = new PdfName("/Filespec"), ["/EF"] = new PdfDictionary { Elements = { ["/F"] = named.Reference } } } };
        doc.Internals.AddObject(annot);

        var target = StandardCrypt.Targets(doc.Internals.Catalog, [doc.Internals.Catalog, page, annot, docXmp, pageXmp, named, typed, other]);
        Assert.Equal(CryptTarget.String, target(null));
        Assert.Equal(CryptTarget.DocumentMetadata, target(docXmp));
        Assert.Equal(CryptTarget.Stream, target(pageXmp));
        Assert.Equal(CryptTarget.EmbeddedFile, target(named));
        Assert.Equal(CryptTarget.EmbeddedFile, target(typed));
        Assert.Equal(CryptTarget.Stream, target(other));
    }

    [Fact]
    public void EachFilterUsesItsOwnKey()
    {
        // Strings AES-128 (the object key salted), streams RC4 (unsalted), at revision 4: each decrypts with its own key.
        var p = Protected("aes-128");
        var h = p.Doc.SecurityHandler;
        PdfObj.Dict(h.Elements["/CF"])!.Elements["/RC4CF"] = Filter("V2");
        h.Elements["/StmF"] = new PdfName("/RC4CF");
        var crypt = Crypt(p)!;
        var key = crypt.FileKey;
        byte[] ObjectKey(bool aes) => MD5.HashData([.. key, 7, 0, 0, 0, 0, .. (aes ? "sAlT"u8.ToArray() : [])])[..Math.Min(key.Length + 5, 16)];

        var s = crypt.Encrypt(7, 0, Data, CryptTarget.String);
        using var aes = Aes.Create();
        aes.Key = ObjectKey(aes: true);
        Assert.Equal(Data, aes.DecryptCbc(s.AsSpan(16), s.AsSpan(0, 16), PaddingMode.PKCS7));
        Assert.Equal(Data, KeptProtection.Rc4(ObjectKey(aes: false), crypt.Encrypt(7, 0, Data, CryptTarget.Stream)));
    }

    [Theory]
    [InlineData("aes-128", "/V", "5")]          // revision 4 with version 5
    [InlineData("aes-256", "/V", "4")]          // revision 6 with version 4
    [InlineData("aes-128", "/CFM", "AESV3")]    // AES-256 at revision 4
    [InlineData("aes-256", "/CFM", "AESV2")]    // AES-128 at revision 6
    [InlineData("aes-256", "/CFM", "V2")]       // RC4 at revision 6
    [InlineData("aes-128", "/Length", "40")]    // AES-128 with a 40-bit key
    [InlineData("rc4-128", "/Length", "200")]   // a key longer than 128 bits
    public void AnInconsistentHandlerIsRefusedAsTheDocumentOpens(string method, string key, string value)
    {
        var p = Protected(method);
        var h = p.Doc.SecurityHandler;
        Assert.NotNull(Crypt(p));
        switch (key)
        {
            case "/CFM":
                PdfObj.Dict(PdfObj.Dict(h.Elements["/CF"])!.Elements["/StdCF"])!.Elements["/CFM"] = new PdfName("/" + value);
                break;
            case "/Length" when value == "40":
                WithKeyLength(h, p.Id0, 40); // a /U that checks out with the shorter key: only the AES filter is wrong
                break;
            default:
                h.Elements[key] = new PdfInteger(int.Parse(value));
                break;
        }
        Assert.Null(Crypt(p));
    }

    /// <summary>The handler (revision 3 or 4) with a key of <paramref name="bits"/> and a /U made with it (algorithms 2 and 5).</summary>
    private static void WithKeyLength(PdfDictionary h, byte[] id0, int bits)
    {
        h.Elements["/Length"] = new PdfInteger(bits);
        var o = KeptProtection.RawBytes(h.Elements["/O"])!;
        var p = unchecked((int)(long)PdfObj.Num(h.Elements["/P"], 0));
        var key = StandardCrypt.Rc4FileKey([], o, p, id0, PdfObj.Int(h.Elements["/R"])!.Value, bits / 8, true);
        var x = KeptProtection.Rc4(key, MD5.HashData([.. KeptProtection.Padding, .. id0]));
        var k = new byte[key.Length];
        for (var i = 1; i <= 19; i++)
        {
            for (var j = 0; j < key.Length; j++) k[j] = (byte)(key[j] ^ i);
            x = KeptProtection.Rc4(k, x);
        }
        h.Elements["/U"] = new PdfString(Encoding.Latin1.GetString([.. x, .. new byte[16]]), PdfStringEncoding.RawEncoding);
    }

    [Fact]
    public void AShorterRc4KeyStillWorks()
    {
        // The /U check of the helper above, on a handler it should accept: RC4 with a 40-bit key at revision 3.
        var p = Protected("rc4-128");
        WithKeyLength(p.Doc.SecurityHandler, p.Id0, 40);
        Assert.Equal(5, Crypt(p)!.FileKey.Length);
    }
}
