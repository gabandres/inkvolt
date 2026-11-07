using System.Security.Cryptography;
using System.Text;
using PdfSharp.Pdf;
using PdfSharp.Pdf.Advanced;

namespace InkvoltPdf.Core;

/// <summary>What is encrypted, for the crypt filter it takes (ISO 32000-2 7.6.5): /StrF, /StmF, /EFF, or none.</summary>
internal enum CryptTarget
{
    /// <summary>A string: /StrF.</summary>
    String,
    /// <summary>A stream's data: /StmF.</summary>
    Stream,
    /// <summary>An embedded file stream: /EFF (else /StmF).</summary>
    EmbeddedFile,
    /// <summary>The document's metadata stream (the catalog's /Metadata): /StmF, or plain when /EncryptMetadata is false.</summary>
    DocumentMetadata,
}

/// <summary>
/// The standard security handler's file key, worked out from the user (open) password, and the encryption of new objects
/// with it (ISO 32000-2 7.6.4; RC4 and AES-128 at revisions 2-4, AES-256 at revisions 5 and 6). The owner password is never
/// needed: whoever opens a document can write objects it will read, which is what an incremental update of a form that
/// allows filling takes (<see cref="UserPasswordEdits"/>).
/// </summary>
internal sealed class StandardCrypt
{
    private enum Method { None, Rc4, Aes128, Aes256 }

    private readonly byte[] _key;
    private readonly Method _strings, _streams, _files;
    private readonly bool _encryptMetadata;

    private StandardCrypt(byte[] key, Method strings, Method streams, Method files, bool encryptMetadata)
    {
        _key = key;
        _strings = strings;
        _streams = streams;
        _files = files;
        _encryptMetadata = encryptMetadata;
    }

    /// <summary>The file key (tests check the object keys made from it).</summary>
    internal byte[] FileKey => _key;

    /// <summary>
    /// The handler of encryption dictionary <paramref name="h"/> opened with <paramref name="password"/> as the user password,
    /// or null when it isn't the standard handler at a revision covered here, a crypt filter is unknown, the dictionary is
    /// inconsistent (a version that doesn't go with its revision, AES-256 below revision 5 or RC4/AES-128 from it, AES-128
    /// with a key other than 128 bits, a key length that isn't 40-128 bits in steps of 8), or the password doesn't check
    /// out against /U. Refused here, as the document opens for editing, so nothing fails after the person has edited.
    /// </summary>
    /// <param name="id0">The first element of the file's /ID (revisions 2-4 mix it into the key).</param>
    public static StandardCrypt? FromUserPassword(PdfDictionary h, byte[] id0, string password)
    {
        if (PdfObj.Name(h.Elements["/Filter"]) != "Standard") return null;
        var r = PdfObj.Int(h.Elements["/R"]) ?? 0;
        var v = PdfObj.Int(h.Elements["/V"]) ?? 0;
        if (r is < 2 or > 6 || v is < 1 or > 5 || v == 3) return null;
        if (r >= 5 != (v == 5)) return null; // AES-256's key is revision 5 and 6's, and only version 5 names it
        if (KeptProtection.RawBytes(h.Elements["/O"]) is not { } o || KeptProtection.RawBytes(h.Elements["/U"]) is not { } u) return null;
        var encryptMetadata = PdfObj.Resolve(h.Elements["/EncryptMetadata"]) is not PdfBoolean { Value: false };

        // The key length in bytes (revisions 2-4): 40 bits at revision 2 and version 1, else /Length (40-128, steps of 8).
        var length = 16;
        if (r <= 4)
        {
            var bits = r == 2 || v == 1 ? 40 : PdfObj.Int(h.Elements["/Length"]) ?? (v == 4 ? 128 : 40);
            if (bits is < 40 or > 128 || bits % 8 != 0) return null;
            length = bits / 8;
        }

        Method strings, streams, files;
        if (v < 4) strings = streams = files = Method.Rc4;
        else
        {
            var cf = PdfObj.Dict(h.Elements["/CF"]);
            Method? Filter(string name)
            {
                if (name == "Identity") return Method.None;
                return PdfObj.Name(PdfObj.Dict(cf?.Elements["/" + name])?.Elements["/CFM"]) switch
                {
                    "None" => Method.None,
                    "V2" => Method.Rc4,
                    "AESV2" => Method.Aes128,
                    "AESV3" => Method.Aes256,
                    _ => null,
                };
            }
            var stmF = PdfObj.Name(h.Elements["/StmF"]) ?? "Identity";
            if (Filter(PdfObj.Name(h.Elements["/StrF"]) ?? "Identity") is not { } s || Filter(stmF) is not { } m ||
                Filter(PdfObj.Name(h.Elements["/EFF"]) ?? stmF) is not { } f)
                return null;
            (strings, streams, files) = (s, m, f);
            foreach (var method in new[] { s, m, f })
            {
                // Each filter goes with the key its revision makes: AES-256 with the 32 bytes of revisions 5 and 6, the
                // others with that of revisions 2-4 (AES-128 with exactly 128 bits).
                if (method != Method.None && method == Method.Aes256 != r >= 5) return null;
                if (method == Method.Aes128 && length != 16) return null;
            }
        }

        byte[]? key;
        if (r <= 4)
        {
            var p = unchecked((int)(long)PdfObj.Num(h.Elements["/P"], 0));
            key = Rc4FileKey(Encoding.Latin1.GetBytes(password), o, p, id0, r, length, encryptMetadata);
            if (!Rc4UserCheck(key, id0, u, r)) return null;
        }
        else
        {
            if (u.Length < 48 || KeptProtection.RawBytes(h.Elements["/UE"]) is not { Length: >= 32 } ue) return null;
            var pw = Encoding.UTF8.GetBytes(password);
            if (pw.Length > 127) pw = pw[..127];
            if (!Hash(pw, u.AsSpan(32, 8), [], r).AsSpan().SequenceEqual(u.AsSpan(0, 32))) return null;
            var intermediate = Hash(pw, u.AsSpan(40, 8), [], r);
            using var aes = Aes.Create();
            aes.Key = intermediate;
            key = aes.DecryptCbc(ue.AsSpan(0, 32), new byte[16], PaddingMode.None);
            // Algorithm 13: /Perms decrypted with the key holds "adb" at 9-11 (revision 5 files may lack it).
            if (KeptProtection.RawBytes(h.Elements["/Perms"]) is { Length: >= 16 } perms)
            {
                aes.Key = key;
                if (!aes.DecryptEcb(perms.AsSpan(0, 16), PaddingMode.None).AsSpan(9, 3).SequenceEqual("adb"u8)) return null;
            }
            else if (r == 6) return null;
        }
        return new StandardCrypt(key, strings, streams, files, encryptMetadata);
    }

    /// <summary>Encrypts a string or a stream's data of object <paramref name="num"/> <paramref name="gen"/>, by what it is.</summary>
    public byte[] Encrypt(int num, int gen, byte[] data, CryptTarget target)
    {
        var method = target switch
        {
            CryptTarget.String => _strings,
            CryptTarget.EmbeddedFile => _files,
            CryptTarget.DocumentMetadata when !_encryptMetadata => Method.None,
            _ => _streams,
        };
        switch (method)
        {
            case Method.None:
                return data;
            case Method.Rc4:
                return KeptProtection.Rc4(ObjectKey(num, gen, method), data);
            default:
                using (var aes = Aes.Create())
                {
                    aes.Key = ObjectKey(num, gen, method);
                    var iv = RandomNumberGenerator.GetBytes(16);
                    return [.. iv, .. aes.EncryptCbc(data, iv, PaddingMode.PKCS7)];
                }
        }
    }

    /// <summary>
    /// What each stream of a document is, for <see cref="Encrypt"/> (null: a string): the catalog's /Metadata is the
    /// document's metadata; a stream an /EF dictionary names (in <paramref name="objects"/> or a dictionary or array held
    /// directly in one) or one typed /EmbeddedFile is an embedded file; any other is a stream.
    /// </summary>
    public static Func<PdfDictionary?, CryptTarget> Targets(PdfDictionary catalog, IEnumerable<PdfObject> objects)
    {
        var metadata = PdfObj.Dict(catalog.Elements["/Metadata"]);
        var files = new HashSet<PdfDictionary>(ReferenceEqualityComparer.Instance);
        foreach (var o in objects) Find(o, 0);
        return d => d is null ? CryptTarget.String
            : ReferenceEquals(d, metadata) ? CryptTarget.DocumentMetadata
            : files.Contains(d) || PdfObj.NameOf(d, "/Type") == "/EmbeddedFile" ? CryptTarget.EmbeddedFile
            : CryptTarget.Stream;

        void Find(PdfItem? item, int depth)
        {
            if (depth > 32) return;
            switch (item)
            {
                case PdfDictionary d:
                    if (PdfObj.Dict(d.Elements["/EF"]) is { } ef)
                        foreach (var f in ef.Elements.Values)
                            if (PdfObj.Dict(f) is { Stream: not null } stream) files.Add(stream);
                    foreach (var value in d.Elements.Values)
                        if (value is not PdfReference) Find(value, depth + 1);
                    break;
                case PdfArray a:
                    foreach (var value in a.Elements)
                        if (value is not PdfReference) Find(value, depth + 1);
                    break;
            }
        }
    }

    /// <summary>True when a stream names its own /Crypt filter, which isn't handled here: such a stream can't be written.</summary>
    public static bool HasOwnCryptFilter(PdfDictionary stream) =>
        PdfObj.Resolve(stream.Elements["/Filter"]) switch
        {
            PdfName n => n.Value == "/Crypt",
            PdfArray a => a.Elements.Any(e => PdfObj.Name(e) == "Crypt"),
            _ => false,
        };

    /// <summary>The key for one object with <paramref name="method"/>: the file key for AES-256, else algorithm 1 (salted for AES-128).</summary>
    private byte[] ObjectKey(int num, int gen, Method method)
    {
        if (method == Method.Aes256) return _key;
        byte[] salt = method == Method.Aes128 ? "sAlT"u8.ToArray() : [];
        byte[] input = [.. _key, (byte)num, (byte)(num >> 8), (byte)(num >> 16), (byte)gen, (byte)(gen >> 8), .. salt];
        return MD5.HashData(input)[..Math.Min(_key.Length + 5, 16)];
    }

    /// <summary>Algorithm 2: the file key from the user password (revisions 2-4).</summary>
    internal static byte[] Rc4FileKey(byte[] password, byte[] o, int p, byte[] id0, int revision, int length, bool encryptMetadata)
    {
        var padded = new byte[32];
        var n = Math.Min(32, password.Length);
        Array.Copy(password, padded, n);
        Array.Copy(KeptProtection.Padding, 0, padded, n, 32 - n);
        using var md5 = IncrementalHash.CreateHash(HashAlgorithmName.MD5);
        md5.AppendData(padded);
        md5.AppendData(o.AsSpan(0, Math.Min(32, o.Length)));
        md5.AppendData([(byte)p, (byte)(p >> 8), (byte)(p >> 16), (byte)(p >> 24)]);
        md5.AppendData(id0);
        if (revision >= 4 && !encryptMetadata) md5.AppendData([0xFF, 0xFF, 0xFF, 0xFF]);
        var hash = md5.GetHashAndReset();
        if (revision >= 3)
            for (var i = 0; i < 50; i++) hash = MD5.HashData(hash.AsSpan(0, length));
        return hash[..length];
    }

    /// <summary>Algorithms 4 and 5 compared with /U: true when <paramref name="key"/> came from the user password.</summary>
    private static bool Rc4UserCheck(byte[] key, byte[] id0, byte[] u, int revision)
    {
        if (revision == 2) return u.Length >= 32 && KeptProtection.Rc4(key, KeptProtection.Padding).AsSpan().SequenceEqual(u.AsSpan(0, 32));
        if (u.Length < 16) return false;
        var x = KeptProtection.Rc4(key, MD5.HashData([.. KeptProtection.Padding, .. id0]));
        var k = new byte[key.Length];
        for (var i = 1; i <= 19; i++)
        {
            for (var j = 0; j < key.Length; j++) k[j] = (byte)(key[j] ^ i);
            x = KeptProtection.Rc4(k, x);
        }
        return x.AsSpan(0, 16).SequenceEqual(u.AsSpan(0, 16));
    }

    /// <summary>The revision 5 hash (SHA-256), or algorithm 2.B for revision 6.</summary>
    internal static byte[] Hash(byte[] password, ReadOnlySpan<byte> salt, byte[] userKey, int revision)
    {
        var k = SHA256.HashData([.. password, .. salt, .. userKey]);
        if (revision == 5) return k;
        using var aes = Aes.Create();
        for (var round = 0; ; round++)
        {
            byte[] one = [.. password, .. k, .. userKey];
            var k1 = new byte[one.Length * 64];
            for (var i = 0; i < 64; i++) one.CopyTo(k1, i * one.Length);
            aes.Key = k[..16];
            var e = aes.EncryptCbc(k1, k.AsSpan(16, 16), PaddingMode.None);
            var mod = 0;
            for (var i = 0; i < 16; i++) mod += e[i];
            k = (mod % 3) switch
            {
                0 => SHA256.HashData(e),
                1 => SHA384.HashData(e),
                _ => SHA512.HashData(e),
            };
            if (round >= 63 && e[^1] <= round + 1 - 32) break;
        }
        return k[..32];
    }
}
