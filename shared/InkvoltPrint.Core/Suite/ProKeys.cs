using System.Security.Cryptography;
using System.Text;

namespace InkvoltPrint.Core.Suite;

/// <summary>What a licence key says: who it was issued to, when, and for which Inkvolt apps ("pdf", "print").</summary>
public sealed record ProLicence(string Name, string Email, DateOnly Issued, IReadOnlyList<string> Products)
{
    public bool Covers(string product) => Products.Contains(product, StringComparer.Ordinal);
}

/// <summary>A key that can't be used, with the reason in plain words (shown as it is).</summary>
public sealed class ProKeyException(string message) : Exception(message);

/// <summary>Where an app keeps the installed key (the app: its settings and the shared file; tests: memory).</summary>
public interface IProStore
{
    string? Read();
    void Write(string? key);
}

public sealed class MemoryProStore(string? key = null) : IProStore
{
    private string? _key = key;

    public string? Read() => _key;

    public void Write(string? key) => _key = key;
}

/// <summary>
/// The Inkvolt Pro licence key, the same for Inkvolt PDF and Inkvolt Print: text a person pastes, <c>INKVOLT-PRO-</c>
/// followed by base32 (RFC 4648, A-Z and 2-7, no padding) in groups of five joined by hyphens. The base32 decodes to a
/// payload followed by a 64-byte signature. The payload is one version byte (1) and UTF-8 text of four lines joined by
/// "\n": name, email, issue date (yyyy-MM-dd), products (comma-separated: "pdf", "print"). The signature is ECDSA P-256
/// over SHA-256 of the whole payload, as r||s (IEEE P1363). The public key is the uncompressed point (0x04, X, Y: 65
/// bytes). Documented, with a test vector, in pdf/tools/pro-key/README.md; the Mac verifies the same key with CryptoKit
/// (P256.Signing).
/// </summary>
public static class ProKeys
{
    public const string Prefix = "INKVOLT-PRO-";
    public const byte Version = 1;
    public const string ProductPdf = "pdf";
    public const string ProductPrint = "print";
    public static readonly IReadOnlyList<string> KnownProducts = [ProductPdf, ProductPrint];

    /// <summary>Inkvolt's licence-signing public key (P-256, uncompressed point, base64). The private key is kept outside the repo.</summary>
    public const string PublicKeyBase64 = "BEWmCvAPieAfsK5Me8N4rjUripueixRJ6g4R3qyY4O7IUNTUc5IUGpOFWUyZ7tTaveT94uIkXQV98EUl/vPXL0Y=";
    public static readonly byte[] PublicKey = Convert.FromBase64String(PublicKeyBase64);

    private const int SignatureLength = 64;
    private const string Alphabet = "ABCDEFGHIJKLMNOPQRSTUVWXYZ234567";
    private const int Group = 5;

    /// <summary>The app a product name stands for, as the refusals name it.</summary>
    public static string ProductName(string product) => product switch
    {
        ProductPdf => "Inkvolt PDF",
        ProductPrint => "Inkvolt Print",
        _ => product,
    };

    /// <summary>Signs a licence with the private key: the key text to send.</summary>
    public static string Issue(ProLicence licence, ECDsa privateKey)
    {
        if (string.IsNullOrWhiteSpace(licence.Name) || HasLineBreak(licence.Name)) throw new ArgumentException("The name is empty or has a line break.", nameof(licence));
        if (string.IsNullOrWhiteSpace(licence.Email) || HasLineBreak(licence.Email)) throw new ArgumentException("The email is empty or has a line break.", nameof(licence));
        if (licence.Products.Count == 0 || licence.Products.Any(p => !KnownProducts.Contains(p)))
            throw new ArgumentException($"Products must be some of {string.Join(", ", KnownProducts)}.", nameof(licence));
        return Encode(Payload(licence), privateKey);
    }

    internal static byte[] Payload(ProLicence licence)
    {
        var text = string.Join('\n', licence.Name.Trim(), licence.Email.Trim(), licence.Issued.ToString("yyyy-MM-dd"), string.Join(',', licence.Products));
        return [Version, .. Encoding.UTF8.GetBytes(text)];
    }

    internal static string Encode(byte[] payload, ECDsa privateKey)
    {
        var signature = privateKey.SignData(payload, HashAlgorithmName.SHA256, DSASignatureFormat.IeeeP1363FixedFieldConcatenation);
        return Prefix + Hyphenate(ToBase32([.. payload, .. signature]));
    }

    /// <summary>Reads and checks a key against Inkvolt's public key.</summary>
    public static ProLicence Parse(string key) => Parse(key, PublicKey);

    /// <summary>Reads and checks a key against <paramref name="publicKey"/> (an uncompressed P-256 point).</summary>
    public static ProLicence Parse(string key, byte[] publicKey)
    {
        var compact = Compact(key);
        if (compact.Length == 0) throw new ProKeyException("Paste the key you were sent.");
        var prefix = Compact(Prefix);
        if (!compact.StartsWith(prefix, StringComparison.Ordinal))
            throw new ProKeyException($"That isn't an Inkvolt Pro key: a key starts with {Prefix}.");
        var body = compact[prefix.Length..];
        if (body.Any(c => !Alphabet.Contains(c)))
            throw new ProKeyException("The key has a character that doesn't belong in it (a key uses the letters A to Z and the digits 2 to 7). Paste it exactly as it was sent.");
        var bytes = FromBase32(body);
        if (bytes.Length < 1 + SignatureLength + 4) throw new ProKeyException("The key is incomplete: paste all of it.");
        if (bytes[0] != Version)
            throw new ProKeyException("This key was made for a newer version of the Inkvolt apps. Update the app, then enter it again.");
        var payload = bytes[..^SignatureLength];
        var signature = bytes[^SignatureLength..];
        if (publicKey.Length != 65 || publicKey[0] != 4) throw new ArgumentException("The public key must be an uncompressed P-256 point (65 bytes).", nameof(publicKey));
        using var ecdsa = ECDsa.Create(new ECParameters
        {
            Curve = ECCurve.NamedCurves.nistP256,
            Q = new ECPoint { X = publicKey[1..33], Y = publicKey[33..65] },
        });
        if (!ecdsa.VerifyData(payload, signature, HashAlgorithmName.SHA256, DSASignatureFormat.IeeeP1363FixedFieldConcatenation))
            throw new ProKeyException("This key has been altered or didn't paste whole. Paste it exactly as it was sent, or ask for it again.");
        string text;
        try
        {
            text = new UTF8Encoding(false, throwOnInvalidBytes: true).GetString(payload, 1, payload.Length - 1);
        }
        catch (DecoderFallbackException)
        {
            throw new ProKeyException("The key's contents can't be read. Ask for it again.");
        }
        var lines = text.Split('\n');
        if (lines.Length != 4 || !DateOnly.TryParseExact(lines[2], "yyyy-MM-dd", out var issued))
            throw new ProKeyException("The key's contents can't be read. Ask for it again.");
        var products = lines[3].Split(',', StringSplitOptions.RemoveEmptyEntries | StringSplitOptions.TrimEntries);
        return new ProLicence(lines[0], lines[1], issued, products);
    }

    /// <summary>The key as it is shown and stored: the prefix, then groups of five, whatever spacing it was pasted with.</summary>
    public static string Format(string key)
    {
        var compact = Compact(key);
        var prefix = Compact(Prefix);
        return compact.StartsWith(prefix, StringComparison.Ordinal) ? Prefix + Hyphenate(compact[prefix.Length..]) : key.Trim();
    }

    private static string Compact(string key) => new([.. key.Where(c => !char.IsWhiteSpace(c) && c != '-').Select(char.ToUpperInvariant)]);

    private static bool HasLineBreak(string s) => s.Any(c => c is '\n' or '\r');

    private static string Hyphenate(string s) => string.Join('-', Enumerable.Range(0, (s.Length + Group - 1) / Group).Select(i => s.Substring(i * Group, Math.Min(Group, s.Length - i * Group))));

    internal static string ToBase32(byte[] bytes)
    {
        var sb = new StringBuilder((bytes.Length * 8 + 4) / 5);
        int buffer = 0, bits = 0;
        foreach (var b in bytes)
        {
            buffer = (buffer << 8) | b;
            bits += 8;
            while (bits >= 5)
            {
                sb.Append(Alphabet[(buffer >> (bits - 5)) & 31]);
                bits -= 5;
            }
        }
        if (bits > 0) sb.Append(Alphabet[(buffer << (5 - bits)) & 31]);
        return sb.ToString();
    }

    internal static byte[] FromBase32(string text)
    {
        var bytes = new List<byte>(text.Length * 5 / 8);
        int buffer = 0, bits = 0;
        foreach (var c in text)
        {
            buffer = (buffer << 5) | Alphabet.IndexOf(c);
            bits += 5;
            if (bits >= 8)
            {
                bytes.Add((byte)((buffer >> (bits - 8)) & 255));
                bits -= 8;
            }
        }
        return [.. bytes];
    }
}
