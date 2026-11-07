using System.Text;
using PdfSharp.Pdf;
using PdfSharp.Pdf.Advanced;
using PdfSharp.Pdf.IO;

namespace InkvoltPdf.Core;

/// <summary>What an edit does, for an encrypted document opened without its permissions (owner) password.</summary>
internal enum UserEdit
{
    /// <summary>Anything else: needs the owner password.</summary>
    None,
    /// <summary>Fills in form fields (and runs their actions): /P bit 9, or bit 6.</summary>
    FillForms,
    /// <summary>Adds or changes comments: /P bit 6.</summary>
    Annotate,
}

/// <summary>
/// Edits an encrypted document with its user (open) password, for what its /P allows: filling in a USCIS or OPM form needs
/// no owner password in Acrobat, Nitro or Preview, and a form's user never has one. PDFsharp opens such a document for
/// editing only with the owner password, so the document is read with the user password, copied decrypted (same object
/// numbers) and opened from that copy; the save is an incremental update of the original encrypted file, which keeps its
/// /Encrypt and /ID and encrypts the new objects with the file key from the user password (<see cref="StandardCrypt"/>,
/// <see cref="Incremental"/>). Anything /P doesn't allow still needs the owner password.
/// </summary>
internal static class UserPasswordEdits
{
    /// <summary>
    /// <paramref name="data"/> opened for <paramref name="edit"/> with the user password (<paramref name="password"/>, or
    /// the empty one), or null when /P doesn't allow it or it can't be done this way (the caller asks for the owner password).
    /// </summary>
    public static PdfDocument? Open(byte[] data, string? password, UserEdit edit)
    {
        if (edit == UserEdit.None) return null;
        byte[] plain;
        StandardCrypt crypt;
        string encrypt;
        (int, int, byte[])? encryptObject = null;
        using (var orig = PdfObj.Read(new MemoryStream(data, writable: false), password, PdfDocumentOpenMode.Import))
        {
            var h = orig.SecurityHandler;
            var permissions = PdfSecurity.Permissions(PdfObj.Num(h.Elements["/P"], 0), PdfObj.Int(h.Elements["/R"]) ?? 0);
            var allowed = edit switch
            {
                UserEdit.FillForms => permissions.FillForms || permissions.Annotate,
                UserEdit.Annotate => permissions.Annotate,
                _ => false,
            };
            if (!allowed || Incremental.Tail(data) is not { Id: { } id } tail) return null;
            if (StandardCrypt.FromUserPassword(h, Convert.FromHexString(id[2..id.IndexOf('>')]), password ?? "") is not { } c) return null;
            crypt = c;
            // Its strings are never encrypted: written back as read. A copy whose /U no longer checks out isn't used.
            var body = Incremental.Serialize(h, _ => null, null);
            if (h.Reference is { } r)
            {
                encrypt = $"{r.ObjectNumber} {r.GenerationNumber} R";
                // Written again only when every string reads back byte for byte (PDFsharp decodes one starting FE FF).
                if (h.Elements.Values.All(v => PdfObj.Resolve(v) is not PdfString s || s.Encoding != PdfStringEncoding.Unicode && s.Value.All(c => c <= 0xFF)))
                    encryptObject = (r.ObjectNumber, r.GenerationNumber, body);
            }
            else encrypt = Encoding.Latin1.GetString(body);
            plain = Plain(orig, h, tail);
        }
        var doc = PdfObj.Read(new MemoryStream(plain, writable: false), null, PdfDocumentOpenMode.Modify);
        if (Incremental.TrackUserPasswordEdit(doc, plain, data, crypt, encrypt, encryptObject)) return doc;
        doc.Dispose();
        return null;
    }

    /// <summary>
    /// The document as a plain PDF with the same object numbers: every object PDFsharp read (decrypted) but the encryption
    /// dictionary and the object and cross-reference streams, a classic xref table, and the original's /Root, /Info and /ID.
    /// </summary>
    private static byte[] Plain(PdfDocument orig, PdfDictionary handler, Incremental.TailInfo tail)
    {
        var objects = orig.Internals.GetAllObjects()
            .Where(o => o.Reference is not null && !ReferenceEquals(o, handler) &&
                        !(o is PdfDictionary d && PdfObj.NameOf(d, "/Type") is "/XRef" or "/ObjStm"))
            .GroupBy(o => o.Reference!.ObjectNumber).Select(g => g.First())
            .OrderBy(o => o.Reference!.ObjectNumber).ToList();
        var numbers = objects.ToDictionary(o => o.Reference!.ObjectID);
        (int, int)? Id(PdfObjectID r) => numbers.ContainsKey(r) ? (r.ObjectNumber, r.GenerationNumber) : null;

        using var ms = new MemoryStream();
        Ascii(ms, "%PDF-1.7\n%âãÏÓ\n");
        var offsets = new Dictionary<int, (long Offset, int Gen)>();
        foreach (var o in objects)
        {
            var (num, gen) = (o.Reference!.ObjectNumber, o.Reference.GenerationNumber);
            offsets[num] = (ms.Position, gen);
            Ascii(ms, $"{num} {gen} obj\n");
            ms.Write(Incremental.Serialize(o, Id, null));
            Ascii(ms, "\nendobj\n");
        }
        var size = (objects.Count == 0 ? 0 : objects[^1].Reference!.ObjectNumber) + 1;
        var xref = ms.Position;
        var sb = new StringBuilder($"xref\n0 {size}\n");
        for (var n = 0; n < size; n++)
            sb.Append(offsets.TryGetValue(n, out var e) ? string.Create(PdfObj.Inv, $"{e.Offset:D10} {e.Gen:D5} n \n") : "0000000000 65535 f \n");
        var root = orig.Internals.Catalog.Reference!;
        var info = tail.HasInfo && orig.Info.Reference is { } ir && numbers.ContainsKey(ir.ObjectID) ? $" /Info {ir.ObjectNumber} {ir.GenerationNumber} R" : "";
        sb.Append(PdfObj.Inv, $"trailer\n<< /Size {size} /Root {root.ObjectNumber} {root.GenerationNumber} R{info} /ID {tail.Id} >>\nstartxref\n{xref}\n%%EOF\n");
        Ascii(ms, sb.ToString());
        return ms.ToArray();
    }

    private static void Ascii(Stream s, string text) => s.Write(Encoding.Latin1.GetBytes(text));
}
