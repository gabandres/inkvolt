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
        using (var orig = PdfObj.Read(data, password, PdfDocumentOpenMode.Import))
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
            var body = EncryptBody(h);
            if (h.Reference is { } r)
            {
                // Written again in the update when it can be (PDFsharp reads a file whose newest section repeats it); else
                // the update names the original object, which stays in the file.
                encrypt = $"{r.ObjectNumber} {r.GenerationNumber} R";
                if (body is not null) encryptObject = (r.ObjectNumber, r.GenerationNumber, body);
            }
            else if (body is not null) encrypt = Encoding.Latin1.GetString(body);
            else return null; // a direct dictionary must be written in the new trailer: it can't be, so the owner password is asked for
            plain = Plain(orig, h, tail);
        }
        PdfShapeGuard.MarkKnown(plain); // written here from a document that was read
        var doc = PdfObj.Read(plain, null, PdfDocumentOpenMode.Modify);
        if (Incremental.TrackUserPasswordEdit(doc, plain, data, crypt, encrypt, encryptObject)) return doc;
        doc.Dispose();
        return null;
    }

    /// <summary>
    /// The encryption dictionary as written again (its strings are never encrypted), or null when it can't be written so
    /// that it reads back byte for byte: a string PDFsharp decoded as text (one starting FE FF) or holding text beyond
    /// Latin-1, anywhere in it. An indirect value keeps its object: the update's numbers are the original's, and the
    /// original's objects stay in the file.
    /// </summary>
    internal static byte[]? EncryptBody(PdfDictionary handler)
    {
        if (!ReadsBack(handler, 0)) return null;
        return Incremental.Serialize(handler, r => (r.ObjectNumber, r.GenerationNumber), null);

        static bool ReadsBack(PdfItem? item, int depth) => depth <= 32 && item switch
        {
            PdfString s => s.Encoding != PdfStringEncoding.Unicode && s.Value.All(c => c <= 0xFF),
            PdfReference => true,
            PdfObject { IsIndirect: true } when depth > 0 => true,
            PdfDictionary d => d.Elements.Values.All(v => ReadsBack(v, depth + 1)),
            PdfArray a => a.Elements.All(v => ReadsBack(v, depth + 1)),
            _ => true,
        };
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
