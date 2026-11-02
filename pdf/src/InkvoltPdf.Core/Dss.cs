using System.IO.Compression;
using System.Security.Cryptography;
using PdfSharp.Pdf;

namespace InkvoltPdf.Core;

/// <summary>One /VRI entry: which of the stored data belongs to one signature.</summary>
/// <param name="Key">The uppercase hex SHA-1 of the signature's /Contents.</param>
internal sealed record VriEntry(string Key, IReadOnlyList<byte[]> Certs, IReadOnlyList<byte[]> Ocsps, IReadOnlyList<byte[]> Crls);

/// <summary>
/// The Document Security Store (ISO 32000-2 12.8.4.3, ETSI EN 319 142-1): the catalog's /DSS with the certificates, OCSP
/// responses and CRLs a signature will need when it is checked years from now, and /VRI saying which belong to which.
/// Reading treats it as hostile: anything of the wrong shape or too large is skipped (<see cref="RevocationPool"/> keeps
/// the limits), compressed streams are inflated only up to what is allowed, and a damaged store is simply no store.
/// </summary>
internal static class Dss
{
    private const int MaxEntries = 1024;

    /// <summary>What <paramref name="doc"/>'s store holds goes into <paramref name="pool"/>. Never throws for a file's sake.</summary>
    public static void ReadInto(PdfDocument doc, RevocationPool pool)
    {
        try
        {
            if (PdfObj.Dict(doc.Internals.Catalog.Elements["/DSS"]) is not { } dss) return;
            ReadList(dss.Elements["/Certs"], RevocationPool.MaxCertBytes, pool.AddCert, pool);
            ReadList(dss.Elements["/OCSPs"], RevocationPool.MaxOcspBytes, pool.AddOcsp, pool);
            ReadList(dss.Elements["/CRLs"], RevocationPool.MaxCrlBytes, pool.AddCrl, pool);
            // /VRI's lists normally name the same streams; a writer may have put some there alone.
            if (PdfObj.Dict(dss.Elements["/VRI"]) is not { } vri) return;
            foreach (var key in vri.Elements.Keys.Take(MaxEntries))
            {
                if (pool.OutOfBudget) return;
                if (PdfObj.Dict(vri.Elements[key]) is not { } entry) continue;
                ReadList(entry.Elements["/Cert"], RevocationPool.MaxCertBytes, pool.AddCert, pool);
                ReadList(entry.Elements["/OCSP"], RevocationPool.MaxOcspBytes, pool.AddOcsp, pool);
                ReadList(entry.Elements["/CRL"], RevocationPool.MaxCrlBytes, pool.AddCrl, pool);
            }
        }
        catch (Exception ex) when (ex is not OutOfMemoryException)
        {
            // A store that can't be read holds nothing.
        }
    }

    private static void ReadList(PdfItem? list, int maxBytes, Action<byte[]> add, RevocationPool pool)
    {
        if (PdfObj.Array(list) is not { } items) return;
        foreach (var item in items.Elements.Take(MaxEntries))
        {
            if (pool.OutOfBudget) return;
            if (PdfObj.Dict(item) is { } stream && Bytes(stream, maxBytes) is { } bytes) add(bytes);
        }
    }

    /// <summary>A stored stream's bytes: unfiltered or plain Flate, at most <paramref name="maxBytes"/>. Other filters aren't used for this data.</summary>
    private static byte[]? Bytes(PdfDictionary stream, int maxBytes)
    {
        if (stream.Stream?.Value is not { } raw) return null;
        var filter = stream.Elements["/Filter"];
        var name = filter is null ? null : PdfObj.Array(filter) is { Elements.Count: 1 } one ? PdfObj.Name(one.Elements[0]) : PdfObj.Name(filter);
        if (filter is null) return raw.Length <= maxBytes ? raw : null;
        if (name != "FlateDecode" || stream.Elements["/DecodeParms"] is not null) return null;
        try
        {
            using var inflate = new ZLibStream(new MemoryStream(raw, writable: false), CompressionMode.Decompress);
            using var output = new MemoryStream();
            var chunk = new byte[16 * 1024];
            while (true)
            {
                var n = inflate.Read(chunk);
                if (n == 0) return output.ToArray();
                if (output.Length + n > maxBytes) return null;
                output.Write(chunk, 0, n);
            }
        }
        catch (InvalidDataException)
        {
            return null;
        }
    }

    /// <summary>
    /// Appends an incremental update that adds these to the store, leaving every earlier byte as it was. Data already in
    /// the store is pointed at, not repeated. Throws <see cref="SigningException"/> when the update can't be written.
    /// </summary>
    public static byte[] Append(byte[] data, string? password, IReadOnlyList<VriEntry> entries)
    {
        using var doc = Signing.OpenForAppend(data, password) ?? throw new SigningException("This document's file structure can't be extended, so long-term data can't be added without breaking its signatures. Nothing was changed.");
        var catalog = doc.Internals.Catalog;
        var dss = PdfObj.Dict(catalog.Elements["/DSS"]);
        if (dss is null)
        {
            dss = new PdfDictionary(doc);
            doc.Internals.AddObject(dss);
            catalog.Elements["/DSS"] = dss.Reference!;
        }

        var certs = Stored(doc, dss, "/Certs");
        var ocsps = Stored(doc, dss, "/OCSPs");
        var crls = Stored(doc, dss, "/CRLs");
        if (PdfObj.Dict(dss.Elements["/VRI"]) is not { } vri)
        {
            vri = new PdfDictionary(doc);
            dss.Elements["/VRI"] = vri;
        }
        var now = PdfObj.DateString(DateTimeOffset.Now);
        foreach (var e in entries)
        {
            var entry = new PdfDictionary(doc);
            if (e.Certs.Count > 0) entry.Elements["/Cert"] = References(doc, e.Certs, certs);
            if (e.Ocsps.Count > 0) entry.Elements["/OCSP"] = References(doc, e.Ocsps, ocsps);
            if (e.Crls.Count > 0) entry.Elements["/CRL"] = References(doc, e.Crls, crls);
            entry.Elements["/TU"] = now;
            vri.Elements["/" + e.Key] = entry;
        }

        // The store is an extension of PDF 1.7 (ISO 32000-2 has it itself); say so unless the file already speaks for one.
        if (PdfObj.Dict(catalog.Elements["/Extensions"]) is not { } extensions)
        {
            extensions = new PdfDictionary(doc);
            catalog.Elements["/Extensions"] = extensions;
        }
        if (extensions.Elements["/ESIC"] is null && extensions.Elements["/ADBE"] is null)
            extensions.Elements["/ESIC"] = new PdfDictionary(doc)
            {
                Elements =
                {
                    ["/BaseVersion"] = new PdfName("/1.7"),
                    ["/ExtensionLevel"] = new PdfInteger(5),
                },
            };

        return Incremental.TrySave(doc, null) ?? throw new SigningException("Long-term data can't be appended to this PDF. Nothing was changed.");
    }

    /// <summary>The store already holds all of this, under these signatures' /VRI keys: an update would add nothing.</summary>
    public static bool Holds(byte[] data, string? password, IReadOnlyList<VriEntry> entries)
    {
        try
        {
            using var doc = PdfObj.Open(data, password, PdfSharp.Pdf.IO.PdfDocumentOpenMode.Import);
            if (PdfObj.Dict(doc.Internals.Catalog.Elements["/DSS"]) is not { } dss || PdfObj.Dict(dss.Elements["/VRI"]) is not { } vri) return false;
            HashSet<string> Hashes(string key) =>
                [.. (PdfObj.Array(dss.Elements[key])?.Elements.Take(MaxEntries) ?? []).Select(PdfObj.Dict).OfType<PdfDictionary>().Select(s => Bytes(s, RevocationPool.MaxCrlBytes)).OfType<byte[]>().Select(Hash)];
            var certs = Hashes("/Certs");
            var ocsps = Hashes("/OCSPs");
            var crls = Hashes("/CRLs");
            return entries.All(e => vri.Elements.ContainsKey("/" + e.Key) && e.Certs.All(c => certs.Contains(Hash(c))) && e.Ocsps.All(c => ocsps.Contains(Hash(c))) && e.Crls.All(c => crls.Contains(Hash(c))));
        }
        catch (Exception ex) when (ex is not OutOfMemoryException)
        {
            return false;
        }
    }

    /// <summary>One /DSS list: its array (made when missing) and what it already holds, by the hash of the bytes.</summary>
    private sealed record Store(PdfArray Array, Dictionary<string, PdfItem> Known);

    private static Store Stored(PdfDocument doc, PdfDictionary dss, string key)
    {
        if (PdfObj.Array(dss.Elements[key]) is not { } array)
        {
            array = new PdfArray(doc);
            dss.Elements[key] = array;
        }
        var known = new Dictionary<string, PdfItem>();
        foreach (var item in array.Elements.Take(MaxEntries))
            if (PdfObj.Dict(item) is { } stream && Bytes(stream, RevocationPool.MaxCrlBytes) is { } bytes)
                known.TryAdd(Hash(bytes), item);
        return new Store(array, known);
    }

    private static PdfArray References(PdfDocument doc, IReadOnlyList<byte[]> items, Store store)
    {
        var refs = new PdfArray(doc);
        foreach (var bytes in items)
        {
            var hash = Hash(bytes);
            if (!store.Known.TryGetValue(hash, out var known))
            {
                var stream = new PdfDictionary(doc);
                stream.CreateStream(bytes);
                doc.Internals.AddObject(stream);
                known = stream.Reference!;
                store.Array.Elements.Add(known);
                store.Known[hash] = known;
            }
            refs.Elements.Add(known);
        }
        return refs;
    }

    private static string Hash(byte[] bytes) => Convert.ToHexString(SHA256.HashData(bytes));
}
