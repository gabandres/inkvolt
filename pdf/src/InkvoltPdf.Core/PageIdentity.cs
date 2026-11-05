using System.Security.Cryptography;
using PdfSharp.Pdf;
using PdfSharp.Pdf.Advanced;
using PdfSharp.Pdf.IO;

namespace InkvoltPdf.Core;

/// <summary>
/// What a page is made of, as one hash: two pages with the same identity run the same content through MuPDF, so a page
/// check's verdict on one holds for the other (an edit leaves most pages as they were; <see cref="PdfEngine.InheritChecks"/>).
/// The hash covers every object the page reaches (its content, resources, pictures, fonts, annotations and their
/// appearances, a widget's field), numbered in the order they are reached rather than by their object numbers (an edit
/// saved whole renumbers them), streams by their bytes as stored (nothing is inflated); the attributes it inherits from
/// the page tree; and what the whole document says about drawing (the form's resources and whether its appearances are
/// made again, optional content). Another page reached (an annotation's /P) counts as a page, not by its content. A
/// page's transparency group of names alone (PDFsharp gives every page one when it saves) is left out: it reaches no
/// stream, so it changes nothing that is read or inflated.
/// </summary>
internal static class PageIdentity
{
    /// <summary>A document bigger than this isn't read for identities (PDFsharp reads it whole): its pages are checked again after an edit.</summary>
    public const int MaxBytes = 32 << 20;

    /// <summary>A page reaching more objects than this has no identity (checked again after an edit).</summary>
    private const int MaxObjects = 50_000;

    private static readonly string[] Inherited = ["/Resources", "/MediaBox", "/CropBox", "/Rotate"];

    /// <summary>Each page's identity (null for a page that has none), or null when the document can't be read for them.</summary>
    public static byte[]?[]? Of(byte[] data, CancellationToken cancel = default)
    {
        if (data.Length > MaxBytes) return null;
        PdfDocument doc;
        try
        {
            doc = PdfObj.Open(data, null, PdfDocumentOpenMode.Import);
        }
        catch (Exception ex) when (ex is not OutOfMemoryException)
        {
            return null; // damaged, or with a password: checked again, as before
        }
        using (doc)
        {
            try
            {
                var streams = new Dictionary<PdfDictionary, byte[]>(ReferenceEqualityComparer.Instance);
                var catalog = doc.Internals.Catalog;
                var form = PdfObj.Dict(catalog.Elements["/AcroForm"]);
                var salt = Hash(form, streams, skip: "/Fields") is { } f && Hash(PdfObj.Dict(catalog.Elements["/OCProperties"]), streams, skip: null) is { } oc
                    ? [.. f, .. oc] : (byte[]?)null;
                if (salt is null) return null;
                var ids = new byte[]?[doc.PageCount];
                for (var i = 0; i < ids.Length; i++)
                {
                    cancel.ThrowIfCancellationRequested();
                    ids[i] = Hash(doc.Pages[i], streams, skip: "/Parent", salt);
                }
                return ids;
            }
            catch (Exception ex) when (ex is not (OutOfMemoryException or OperationCanceledException))
            {
                return null; // something PDFsharp couldn't follow: checked again, as before
            }
        }
    }

    /// <summary>The hash of <paramref name="root"/> and all it reaches (empty for none); null when it reaches too much.</summary>
    private static byte[]? Hash(PdfDictionary? root, Dictionary<PdfDictionary, byte[]> streams, string? skip, byte[]? salt = null)
    {
        using var hash = IncrementalHash.CreateHash(HashAlgorithmName.SHA256);
        if (salt is not null) hash.AppendData(salt);
        if (root is null) return hash.GetHashAndReset();

        // Every indirect object reached, numbered in the order reached: the root first, keys in order, another page not entered.
        var order = new Dictionary<PdfObjectID, int>();
        var list = new List<PdfObject>();
        var stack = new Stack<PdfItem?>();
        var leave = new HashSet<string>(StringComparer.Ordinal);
        if (skip is not null) leave.Add(skip);
        if (skip == "/Parent" && root.Elements["/Group"] is PdfDictionary { Reference: null } group
            && group.Elements.Values.All(v => v is PdfName or PdfBoolean or PdfInteger or PdfReal))
            leave.Add("/Group");
        void Children(PdfItem? item, IReadOnlySet<string>? leaveOut)
        {
            switch (item)
            {
                case PdfDictionary d:
                    foreach (var key in d.Elements.Keys.OrderDescending(StringComparer.Ordinal))
                        if (leaveOut?.Contains(key) != true) stack.Push(d.Elements[key]);
                    break;
                case PdfArray a:
                    for (var i = a.Elements.Count - 1; i >= 0; i--) stack.Push(a.Elements[i]);
                    break;
            }
        }
        bool Reach(PdfObject target)
        {
            if (target.Reference is not { } r || order.ContainsKey(r.ObjectID)) return false;
            if (target != root && target is PdfDictionary d && PdfObj.NameOf(d, "/Type") is "/Page" or "/Pages") return false;
            order[r.ObjectID] = list.Count;
            list.Add(target);
            return true;
        }

        if (root.Reference is not null) Reach(root);
        Children(root, leave);
        // What a page inherits from the page tree, reached as if it were its own.
        var inherited = new List<(string Key, PdfItem Value)>();
        if (skip == "/Parent")
            foreach (var key in Inherited)
                if (!root.Elements.ContainsKey(key) && InheritedValue(root, key) is { } value)
                {
                    inherited.Add((key, value));
                    stack.Push(value);
                }
        while (stack.Count > 0)
        {
            var item = stack.Pop();
            switch (item)
            {
                case PdfReference r:
                    if (r.Value is { } v && Reach(v)) Children(v, null);
                    break;
                case PdfObject { IsIndirect: true } o:
                    if (Reach(o)) Children(o, null);
                    break;
                case PdfDictionary or PdfArray:
                    Children(item, null);
                    break;
            }
            if (list.Count > MaxObjects) return null;
        }

        (int, int)? Id(PdfObjectID id) => order.TryGetValue(id, out var n) ? (n, 0) : (-1, 0); // -1: another page
        if (root.Reference is null) hash.AppendData(Incremental.Serialize(root, Id, streams, leave));
        foreach (var obj in list) hash.AppendData(Incremental.Serialize(obj, Id, streams, obj == root ? leave : null));
        foreach (var (key, value) in inherited)
        {
            hash.AppendData(System.Text.Encoding.ASCII.GetBytes(key));
            var reference = value as PdfReference ?? (value as PdfObject)?.Reference;
            if (reference is not null) hash.AppendData(BitConverter.GetBytes(Id(reference.ObjectID)!.Value.Item1));
            else if (value is PdfObject direct) hash.AppendData(Incremental.Serialize(direct, Id, streams));
            else hash.AppendData(System.Text.Encoding.ASCII.GetBytes(value.ToString() ?? ""));
        }
        return hash.GetHashAndReset();
    }

    /// <summary>The value of <paramref name="key"/> a page inherits from its ancestors in the page tree; null if none has it.</summary>
    private static PdfItem? InheritedValue(PdfDictionary page, string key)
    {
        var node = PdfObj.Dict(page.Elements["/Parent"]);
        for (var depth = 0; node is not null && depth < 64; depth++, node = PdfObj.Dict(node.Elements["/Parent"]))
            if (node.Elements[key] is { } value) return value;
        return null;
    }
}
