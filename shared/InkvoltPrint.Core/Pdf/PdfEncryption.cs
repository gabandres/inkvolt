using System.Globalization;
using System.Security.Cryptography;
using System.Text;
using System.Text.RegularExpressions;

namespace InkvoltPrint.Core.Pdf;

/// <summary>Why a new password can't be used yet (<see cref="PdfEncryption.CheckNew"/>).</summary>
public enum NewPasswordProblem { Empty, Mismatch }

/// <summary>
/// A password on a PDF that <see cref="PdfWriter"/> writes: AES-256, the standard security handler's revision 6 (ISO 32000-2,
/// 7.6.4.3 and 7.6.4.4), as Inkvolt PDF's Protect writes it. One password opens the file and, everything being allowed,
/// stands for the owner's too. A new random file key every time; each string and stream gets its own random IV.
/// </summary>
public sealed partial class PdfEncryption
{
    /// <summary>A password's bytes are cut to this many (7.6.4.3.3).</summary>
    public const int MaxPasswordBytes = 127;

    /// <summary>Every permission (bits 1 and 2 clear, as 7.6.4.2 requires): printing, copying, changing, all of it.</summary>
    internal const int AllPermissions = -4;

    private readonly byte[] _key;

    private PdfEncryption(byte[] key, byte[] u, byte[] ue, byte[] o, byte[] oe, byte[] perms)
    {
        _key = key;
        U = u;
        UE = ue;
        O = o;
        OE = oe;
        Perms = perms;
    }

    internal byte[] U { get; }
    internal byte[] UE { get; }
    internal byte[] O { get; }
    internal byte[] OE { get; }
    internal byte[] Perms { get; }

    /// <summary>Whether a password can protect a file: not empty (an empty one opens it without asking).</summary>
    public static bool Usable(string? password) => !string.IsNullOrEmpty(password) && PasswordBytes(password).Length > 0;

    /// <summary>What stops a new password typed twice from being used, or null: nothing typed, or the two differ.</summary>
    public static NewPasswordProblem? CheckNew(string? password, string? again) =>
        !Usable(password) ? Pdf.NewPasswordProblem.Empty
        : !string.Equals(password, again, StringComparison.Ordinal) ? Pdf.NewPasswordProblem.Mismatch
        : null;

    /// <summary>A new file key and the dictionary's values for <paramref name="password"/>.</summary>
    /// <exception cref="ArgumentException">The password is empty.</exception>
    public static PdfEncryption Create(string password)
    {
        if (!Usable(password)) throw new ArgumentException("A password is needed.", nameof(password));
        var pw = PasswordBytes(password);
        var key = RandomNumberGenerator.GetBytes(32);
        var userSalts = RandomNumberGenerator.GetBytes(16);
        var u = Concat(Hash(pw, userSalts.AsSpan(0, 8), []), userSalts);
        var ue = AesNoPadding(Hash(pw, userSalts.AsSpan(8, 8), []), key);
        var ownerSalts = RandomNumberGenerator.GetBytes(16);
        var o = Concat(Hash(pw, ownerSalts.AsSpan(0, 8), u), ownerSalts);
        var oe = AesNoPadding(Hash(pw, ownerSalts.AsSpan(8, 8), u), key);
        var perms = new byte[16];
        BitConverter.TryWriteBytes(perms.AsSpan(0, 4), AllPermissions); // little-endian on every .NET platform Inkvolt runs on
        perms[4] = perms[5] = perms[6] = perms[7] = 0xFF;
        perms[8] = (byte)'T'; // the metadata is encrypted too
        "adb"u8.CopyTo(perms.AsSpan(9));
        RandomNumberGenerator.Fill(perms.AsSpan(12));
        using (var aes = Aes.Create())
        {
            aes.Key = key;
            perms = aes.EncryptEcb(perms, PaddingMode.None);
        }
        return new PdfEncryption(key, u, ue, o, oe, perms);
    }

    /// <summary>The /Encrypt dictionary (its strings are never encrypted themselves).</summary>
    public string Dictionary() =>
        "<< /Filter /Standard /V 5 /R 6 /Length 256 /CF << /StdCF << /Type /CryptFilter /CFM /AESV3 /AuthEvent /DocOpen /Length 32 >> >> " +
        $"/StmF /StdCF /StrF /StdCF /P {AllPermissions.ToString(CultureInfo.InvariantCulture)} /EncryptMetadata true " +
        $"/O <{Convert.ToHexString(O)}> /U <{Convert.ToHexString(U)}> /OE <{Convert.ToHexString(OE)}> /UE <{Convert.ToHexString(UE)}> /Perms <{Convert.ToHexString(Perms)}> >>";

    /// <summary>A string's or a stream's bytes encrypted: a random 16-byte IV, then AES-256-CBC with PKCS#7 padding (7.6.3.2).</summary>
    public byte[] Encrypt(ReadOnlySpan<byte> data)
    {
        using var aes = Aes.Create();
        aes.Key = _key;
        var iv = RandomNumberGenerator.GetBytes(16);
        return Concat(iv, aes.EncryptCbc(data, iv, PaddingMode.PKCS7));
    }

    /// <summary>
    /// An object's dictionary or array as <see cref="PdfWriter"/> wrote it, with every string in it encrypted and written as hex.
    /// Literal strings (escapes and balanced parentheses) and hex strings are read; names, numbers and <c>&lt;&lt;</c> pass through.
    /// </summary>
    public string EncryptStrings(string body)
    {
        var sb = new StringBuilder(body.Length + 64);
        for (var i = 0; i < body.Length;)
        {
            var c = body[i];
            if (c == '(')
            {
                var (bytes, end) = Literal(body, i);
                sb.Append('<').Append(Convert.ToHexString(Encrypt(bytes))).Append('>');
                i = end;
            }
            else if (c == '<' && i + 1 < body.Length && body[i + 1] == '<')
            {
                sb.Append("<<");
                i += 2;
            }
            else if (c == '<')
            {
                var close = body.IndexOf('>', i + 1);
                if (close < 0) throw new FormatException("An unclosed hex string.");
                var hex = HexChars().Replace(body[(i + 1)..close], "");
                if (hex.Length % 2 == 1) hex += "0";
                sb.Append('<').Append(Convert.ToHexString(Encrypt(Convert.FromHexString(hex)))).Append('>');
                i = close + 1;
            }
            else
            {
                sb.Append(c);
                i++;
            }
        }
        return sb.ToString();
    }

    /// <summary>A literal string at <paramref name="start"/> (its opening parenthesis): its bytes and the index after its closing one.</summary>
    private static (byte[] Bytes, int End) Literal(string body, int start)
    {
        var bytes = new List<byte>();
        var depth = 0;
        for (var i = start; i < body.Length; i++)
        {
            var c = body[i];
            if (c == '\\' && i + 1 < body.Length)
            {
                var n = body[++i];
                switch (n)
                {
                    case 'n': bytes.Add((byte)'\n'); break;
                    case 'r': bytes.Add((byte)'\r'); break;
                    case 't': bytes.Add((byte)'\t'); break;
                    case 'b': bytes.Add((byte)'\b'); break;
                    case 'f': bytes.Add((byte)'\f'); break;
                    case >= '0' and <= '7':
                        var value = n - '0';
                        for (var k = 0; k < 2 && i + 1 < body.Length && body[i + 1] is >= '0' and <= '7'; k++) value = value * 8 + (body[++i] - '0');
                        bytes.Add((byte)value);
                        break;
                    case '\r' or '\n': break; // a line continued
                    default: bytes.Add((byte)n); break;
                }
                continue;
            }
            if (c == '(' && depth++ == 0) continue;
            if (c == ')' && --depth == 0) return ([.. bytes], i + 1);
            bytes.Add((byte)c);
        }
        throw new FormatException("An unclosed string.");
    }

    [GeneratedRegex(@"\s")]
    private static partial Regex HexChars();

    /// <summary>
    /// A password's bytes: UTF-8 of its compatibility form (NFKC; SASLprep's normalization, 7.6.4.3.3), at most
    /// <see cref="MaxPasswordBytes"/>, never cutting a character in two.
    /// </summary>
    public static byte[] PasswordBytes(string password)
    {
        var text = password.Normalize(NormalizationForm.FormKC);
        var bytes = Encoding.UTF8.GetBytes(text);
        if (bytes.Length <= MaxPasswordBytes) return bytes;
        var cut = MaxPasswordBytes;
        while (cut > 0 && (bytes[cut] & 0xC0) == 0x80) cut--;
        return bytes[..cut];
    }

    /// <summary>Algorithm 2.B (7.6.4.3.4): the hash of a password with a salt and, for the owner's values, the user's 48 bytes.</summary>
    internal static byte[] Hash(ReadOnlySpan<byte> password, ReadOnlySpan<byte> salt, ReadOnlySpan<byte> userKey)
    {
        var k = SHA256.HashData(Concat(password.ToArray(), salt.ToArray(), userKey.ToArray()));
        var e = Array.Empty<byte>();
        using var aes = Aes.Create();
        for (var round = 0; round < 64 || e[^1] > round - 32; round++)
        {
            var one = Concat(password.ToArray(), k, userKey.ToArray());
            var k1 = new byte[one.Length * 64];
            for (var r = 0; r < 64; r++) one.CopyTo(k1, r * one.Length);
            aes.Key = k[..16];
            e = aes.EncryptCbc(k1, k.AsSpan(16, 16), PaddingMode.None);
            var sum = 0;
            for (var b = 0; b < 16; b++) sum += e[b];
            k = (sum % 3) switch
            {
                0 => SHA256.HashData(e),
                1 => SHA384.HashData(e),
                _ => SHA512.HashData(e),
            };
        }
        return k[..32];
    }

    /// <summary>AES-256-CBC with a zero IV and no padding, for /UE and /OE.</summary>
    internal static byte[] AesNoPadding(byte[] key, byte[] data)
    {
        using var aes = Aes.Create();
        aes.Key = key;
        return aes.EncryptCbc(data, new byte[16], PaddingMode.None);
    }

    private static byte[] Concat(params byte[][] parts)
    {
        var all = new byte[parts.Sum(p => p.Length)];
        var at = 0;
        foreach (var p in parts)
        {
            p.CopyTo(all, at);
            at += p.Length;
        }
        return all;
    }
}
