using System.Formats.Asn1;
using System.Numerics;
using System.Security.Cryptography;
using System.Security.Cryptography.X509Certificates;
using System.Text;

namespace InkvoltPdf.Core;

/// <summary>What a certificate names and how it was signed, read from its bytes. Nothing here goes online.</summary>
internal static class CertFacts
{
    public const string OcspSigningEku = "1.3.6.1.5.5.7.3.9";
    private const string OcspNoCheckOid = "1.3.6.1.5.5.7.48.1.5";
    private const string AiaOid = "1.3.6.1.5.5.7.1.1";
    private const string CdpOid = "2.5.29.31";

    /// <summary>At most this many addresses of each kind are read from one certificate: real ones name one or two.</summary>
    private const int MaxUrls = 4;

    public static IReadOnlyList<string> OcspUrls(X509Certificate2 c) => Aia(c, a => a.EnumerateOcspUris());

    public static IReadOnlyList<string> IssuerUrls(X509Certificate2 c) => Aia(c, a => a.EnumerateCAIssuersUris());

    private static IReadOnlyList<string> Aia(X509Certificate2 c, Func<X509AuthorityInformationAccessExtension, IEnumerable<string>> pick)
    {
        try
        {
            if (c.Extensions[AiaOid] is not { } ext) return [];
            return [.. pick(new X509AuthorityInformationAccessExtension(ext.RawData, ext.Critical)).Take(MaxUrls)];
        }
        catch (Exception ex) when (ex is CryptographicException or AsnContentException or ArgumentException or InvalidOperationException)
        {
            return [];
        }
    }

    /// <summary>The URIs of a certificate's CRL distribution points (RFC 5280 4.2.1.13).</summary>
    public static IReadOnlyList<string> CrlUrls(X509Certificate2 c)
    {
        var urls = new List<string>();
        try
        {
            if (c.Extensions[CdpOid] is not { } ext) return urls;
            var points = new AsnReader(ext.RawData, AsnEncodingRules.BER).ReadSequence();
            while (points.HasData && urls.Count < MaxUrls)
            {
                var point = points.ReadSequence();
                if (!point.HasData || !point.PeekTag().HasSameClassAndValue(new Asn1Tag(TagClass.ContextSpecific, 0))) continue;
                var name = point.ReadSequence(new Asn1Tag(TagClass.ContextSpecific, 0, true));
                if (!name.HasData || !name.PeekTag().HasSameClassAndValue(new Asn1Tag(TagClass.ContextSpecific, 0))) continue;
                var general = name.ReadSequence(new Asn1Tag(TagClass.ContextSpecific, 0, true));
                while (general.HasData)
                {
                    var tag = general.PeekTag();
                    if (tag.HasSameClassAndValue(new Asn1Tag(TagClass.ContextSpecific, 6)))
                        urls.Add(general.ReadCharacterString(UniversalTagNumber.IA5String, new Asn1Tag(TagClass.ContextSpecific, 6)));
                    else general.ReadEncodedValue();
                }
            }
        }
        catch (Exception ex) when (ex is CryptographicException or AsnContentException or ArgumentException or InvalidOperationException)
        {
            // A damaged extension names nothing.
        }
        return urls;
    }

    /// <summary>The certificate says its OCSP responder needn't be checked itself (RFC 6960 4.2.2.2.1).</summary>
    public static bool HasOcspNoCheck(X509Certificate2 c) => c.Extensions[OcspNoCheckOid] is not null;

    public static bool HasEku(X509Certificate2 c, string eku) =>
        c.Extensions.OfType<X509EnhancedKeyUsageExtension>().Any(e => e.EnhancedKeyUsages.Cast<Oid>().Any(o => o.Value == eku));

    /// <summary>Issued by itself: nobody else can say it was revoked, whoever trusts it does so directly.</summary>
    public static bool IsSelfSigned(X509Certificate2 c) =>
        c.SubjectName.RawData.AsSpan().SequenceEqual(c.IssuerName.RawData) && SignedBy(c, c);

    /// <summary>True when <paramref name="issuer"/>'s key signed <paramref name="cert"/>.</summary>
    public static bool SignedBy(X509Certificate2 cert, X509Certificate2 issuer)
    {
        try
        {
            var outer = new AsnReader(cert.RawData, AsnEncodingRules.BER).ReadSequence();
            var tbs = outer.ReadEncodedValue();
            var alg = outer.ReadEncodedValue();
            var sig = outer.ReadBitString(out _);
            return DerSignature.Verify(issuer, alg.Span, tbs.Span, sig);
        }
        catch (Exception ex) when (ex is AsnContentException or CryptographicException or ArgumentException)
        {
            return false;
        }
    }

    public static string Name(X509Certificate2 c)
    {
        var name = c.GetNameInfo(X509NameType.SimpleName, false);
        return string.IsNullOrEmpty(name) ? c.Subject : name;
    }
}

/// <summary>Checks an AlgorithmIdentifier-style signature with a certificate's public key: RSA (PKCS#1, PSS) and ECDSA.</summary>
internal static class DerSignature
{
    public static bool Verify(X509Certificate2 signer, ReadOnlySpan<byte> algorithm, ReadOnlySpan<byte> signed, ReadOnlySpan<byte> signature)
    {
        try
        {
            var alg = new AsnReader(algorithm.ToArray(), AsnEncodingRules.BER).ReadSequence();
            var oid = alg.ReadObjectIdentifier();
            switch (oid)
            {
                case "1.2.840.113549.1.1.5": return Rsa(signer, signed, signature, HashAlgorithmName.SHA1, RSASignaturePadding.Pkcs1);
                case "1.2.840.113549.1.1.11": return Rsa(signer, signed, signature, HashAlgorithmName.SHA256, RSASignaturePadding.Pkcs1);
                case "1.2.840.113549.1.1.12": return Rsa(signer, signed, signature, HashAlgorithmName.SHA384, RSASignaturePadding.Pkcs1);
                case "1.2.840.113549.1.1.13": return Rsa(signer, signed, signature, HashAlgorithmName.SHA512, RSASignaturePadding.Pkcs1);
                case "1.2.840.113549.1.1.10": return Rsa(signer, signed, signature, PssHash(alg), RSASignaturePadding.Pss);
                case "1.2.840.10045.4.1": return Ec(signer, signed, signature, HashAlgorithmName.SHA1);
                case "1.2.840.10045.4.3.2": return Ec(signer, signed, signature, HashAlgorithmName.SHA256);
                case "1.2.840.10045.4.3.3": return Ec(signer, signed, signature, HashAlgorithmName.SHA384);
                case "1.2.840.10045.4.3.4": return Ec(signer, signed, signature, HashAlgorithmName.SHA512);
                default: return false;
            }
        }
        catch (Exception ex) when (ex is CryptographicException or AsnContentException or ArgumentException or NotSupportedException)
        {
            return false;
        }
    }

    private static bool Rsa(X509Certificate2 signer, ReadOnlySpan<byte> signed, ReadOnlySpan<byte> signature, HashAlgorithmName hash, RSASignaturePadding padding)
    {
        using var key = signer.GetRSAPublicKey();
        return key is not null && key.VerifyData(signed, signature, hash, padding);
    }

    private static bool Ec(X509Certificate2 signer, ReadOnlySpan<byte> signed, ReadOnlySpan<byte> signature, HashAlgorithmName hash)
    {
        using var key = signer.GetECDsaPublicKey();
        return key is not null && key.VerifyData(signed, signature, hash, DSASignatureFormat.Rfc3279DerSequence);
    }

    /// <summary>The hash of RSASSA-PSS parameters (RFC 4055: [0] hashAlgorithm, SHA-1 when left out).</summary>
    private static HashAlgorithmName PssHash(AsnReader alg)
    {
        if (!alg.HasData) return HashAlgorithmName.SHA1;
        var pars = alg.ReadSequence();
        if (!pars.HasData || !pars.PeekTag().HasSameClassAndValue(new Asn1Tag(TagClass.ContextSpecific, 0))) return HashAlgorithmName.SHA1;
        var hash = pars.ReadSequence(new Asn1Tag(TagClass.ContextSpecific, 0, true)).ReadSequence().ReadObjectIdentifier();
        return hash switch
        {
            "2.16.840.1.101.3.4.2.1" => HashAlgorithmName.SHA256,
            "2.16.840.1.101.3.4.2.2" => HashAlgorithmName.SHA384,
            "2.16.840.1.101.3.4.2.3" => HashAlgorithmName.SHA512,
            "1.3.14.3.2.26" => HashAlgorithmName.SHA1,
            _ => throw new NotSupportedException(),
        };
    }
}

internal enum OcspCertStatus { Good, Revoked, Unknown }

/// <summary>One certificate's answer in an OCSP response.</summary>
internal sealed record OcspSingle(string HashOid, byte[] IssuerNameHash, byte[] IssuerKeyHash, BigInteger Serial, OcspCertStatus Status,
    DateTimeOffset ThisUpdate, DateTimeOffset? NextUpdate, DateTimeOffset? RevokedAt);

/// <summary>A parsed OCSP response (RFC 6960), whole so it can be stored as is.</summary>
internal sealed class OcspResponse
{
    private const string BasicOid = "1.3.6.1.5.5.7.48.1.1";
    private const int MaxSingles = 64;
    private const int MaxCerts = 8;

    public required byte[] Der { get; init; }
    public required byte[] Tbs { get; init; }
    public required byte[] Algorithm { get; init; }
    public required byte[] Signature { get; init; }
    public required DateTimeOffset ProducedAt { get; init; }
    public required IReadOnlyList<OcspSingle> Singles { get; init; }
    public required IReadOnlyList<X509Certificate2> Certs { get; init; }

    /// <summary>The DER of a request for one certificate: SHA-1 CertID, as RFC 5019 asks, and no nonce (the answer is kept as evidence and judged by its dates).</summary>
    public static byte[] Request(X509Certificate2 cert, X509Certificate2 issuer)
    {
        var w = new AsnWriter(AsnEncodingRules.DER);
        using (w.PushSequence())
        using (w.PushSequence())
        using (w.PushSequence())
        using (w.PushSequence())
        using (w.PushSequence())
        {
            using (w.PushSequence())
            {
                w.WriteObjectIdentifier("1.3.14.3.2.26");
                w.WriteNull();
            }
            w.WriteOctetString(SHA1.HashData(cert.IssuerName.RawData));
            w.WriteOctetString(SHA1.HashData(issuer.PublicKey.EncodedKeyValue.RawData));
            w.WriteInteger(Convert.FromHexString(cert.SerialNumber));
        }
        return w.Encode();
    }

    /// <summary>The response, or null with <paramref name="problem"/> when it isn't a successful basic response or can't be read.</summary>
    public static OcspResponse? Parse(byte[] der, out string? problem)
    {
        problem = null;
        try
        {
            var outer = new AsnReader(der, AsnEncodingRules.BER).ReadSequence();
            var status = outer.ReadEnumeratedValue<OcspResponseStatus>();
            if (status != OcspResponseStatus.Successful)
            {
                problem = status switch
                {
                    OcspResponseStatus.TryLater => "the responder says to try later",
                    OcspResponseStatus.Unauthorized => "the responder doesn't answer for this certificate",
                    _ => "the responder reported an error",
                };
                return null;
            }
            var bytes = outer.ReadSequence(new Asn1Tag(TagClass.ContextSpecific, 0, true)).ReadSequence();
            if (bytes.ReadObjectIdentifier() != BasicOid)
            {
                problem = "the response is of an unknown kind";
                return null;
            }
            var basic = new AsnReader(bytes.ReadOctetString(), AsnEncodingRules.BER).ReadSequence();
            var tbsDer = basic.ReadEncodedValue();
            var algorithm = basic.ReadEncodedValue();
            var signature = basic.ReadBitString(out _);
            var certs = new List<X509Certificate2>();
            if (basic.HasData && basic.PeekTag().HasSameClassAndValue(new Asn1Tag(TagClass.ContextSpecific, 0)))
            {
                var list = basic.ReadSequence(new Asn1Tag(TagClass.ContextSpecific, 0, true)).ReadSequence();
                while (list.HasData && certs.Count < MaxCerts) certs.Add(X509CertificateLoader.LoadCertificate(list.ReadEncodedValue().Span));
            }

            var tbs = new AsnReader(tbsDer, AsnEncodingRules.BER).ReadSequence();
            if (tbs.PeekTag().HasSameClassAndValue(new Asn1Tag(TagClass.ContextSpecific, 0))) tbs.ReadEncodedValue(); // version
            tbs.ReadEncodedValue(); // responderID: the signature check below is what counts
            var produced = tbs.ReadGeneralizedTime();
            var answers = tbs.ReadSequence();
            var singles = new List<OcspSingle>();
            while (answers.HasData && singles.Count < MaxSingles) singles.Add(ReadSingle(answers.ReadSequence()));
            return new OcspResponse
            {
                Der = der,
                Tbs = tbsDer.ToArray(),
                Algorithm = algorithm.ToArray(),
                Signature = signature,
                ProducedAt = produced,
                Singles = singles,
                Certs = certs,
            };
        }
        catch (Exception ex) when (ex is AsnContentException or CryptographicException or ArgumentException or OverflowException)
        {
            problem = "the response can't be read";
            return null;
        }
    }

    private static OcspSingle ReadSingle(AsnReader s)
    {
        var id = s.ReadSequence();
        var hashOid = id.ReadSequence().ReadObjectIdentifier();
        var nameHash = id.ReadOctetString();
        var keyHash = id.ReadOctetString();
        var serial = id.ReadInteger();
        var tag = s.PeekTag();
        var status = OcspCertStatus.Unknown;
        DateTimeOffset? revokedAt = null;
        if (tag.HasSameClassAndValue(new Asn1Tag(TagClass.ContextSpecific, 0)))
        {
            status = OcspCertStatus.Good;
            s.ReadEncodedValue();
        }
        else if (tag.HasSameClassAndValue(new Asn1Tag(TagClass.ContextSpecific, 1)))
        {
            status = OcspCertStatus.Revoked;
            revokedAt = s.ReadSequence(new Asn1Tag(TagClass.ContextSpecific, 1, true)).ReadGeneralizedTime();
        }
        else s.ReadEncodedValue();
        var thisUpdate = s.ReadGeneralizedTime();
        DateTimeOffset? nextUpdate = null;
        if (s.HasData && s.PeekTag().HasSameClassAndValue(new Asn1Tag(TagClass.ContextSpecific, 0)))
            nextUpdate = s.ReadSequence(new Asn1Tag(TagClass.ContextSpecific, 0, true)).ReadGeneralizedTime();
        return new OcspSingle(hashOid, nameHash, keyHash, serial, status, thisUpdate, nextUpdate, revokedAt);
    }

    /// <summary>The answer about <paramref name="cert"/> issued by <paramref name="issuer"/>, when this response holds one.</summary>
    public OcspSingle? AnswerFor(X509Certificate2 cert, X509Certificate2 issuer)
    {
        var serial = new BigInteger(Convert.FromHexString(cert.SerialNumber), isUnsigned: false, isBigEndian: true);
        foreach (var s in Singles)
        {
            if (s.Serial != serial) continue;
            Func<byte[], byte[]>? hash = s.HashOid switch
            {
                "1.3.14.3.2.26" => SHA1.HashData,
                "2.16.840.1.101.3.4.2.1" => SHA256.HashData,
                "2.16.840.1.101.3.4.2.2" => SHA384.HashData,
                "2.16.840.1.101.3.4.2.3" => SHA512.HashData,
                _ => null,
            };
            if (hash is null) continue;
            if (s.IssuerNameHash.AsSpan().SequenceEqual(hash(cert.IssuerName.RawData)) &&
                s.IssuerKeyHash.AsSpan().SequenceEqual(hash(issuer.PublicKey.EncodedKeyValue.RawData)))
                return s;
        }
        return null;
    }

    /// <summary>
    /// Who signed this response for <paramref name="issuer"/>: the issuer itself (null in the result's Responder), or a
    /// responder it delegated to (issued by it, for OCSP signing, valid when the response was made). False when neither did.
    /// </summary>
    public bool SignedFor(X509Certificate2 issuer, IEnumerable<X509Certificate2> known, out X509Certificate2? responder)
    {
        responder = null;
        if (DerSignature.Verify(issuer, Algorithm, Tbs, Signature)) return true;
        foreach (var c in Certs.Concat(known).Take(MaxCerts * 4))
        {
            if (!c.IssuerName.RawData.AsSpan().SequenceEqual(issuer.SubjectName.RawData) || !CertFacts.HasEku(c, CertFacts.OcspSigningEku)) continue;
            if (ProducedAt.UtcDateTime < c.NotBefore.ToUniversalTime() || ProducedAt.UtcDateTime > c.NotAfter.ToUniversalTime()) continue;
            if (DerSignature.Verify(c, Algorithm, Tbs, Signature) && CertFacts.SignedBy(c, issuer))
            {
                responder = c;
                return true;
            }
        }
        return false;
    }
}

internal enum OcspResponseStatus { Successful = 0, MalformedRequest = 1, InternalError = 2, TryLater = 3, SigRequired = 5, Unauthorized = 6 }

/// <summary>A parsed certificate revocation list (RFC 5280), whole so it can be stored as is. Its entries are scanned when asked, not kept.</summary>
internal sealed class CrlDocument
{
    private const string DeltaIndicatorOid = "2.5.29.27";
    private const string DistributionPointOid = "2.5.29.28";

    public required byte[] Der { get; init; }
    public required byte[] Tbs { get; init; }
    public required byte[] Algorithm { get; init; }
    public required byte[] Signature { get; init; }
    public required byte[] IssuerName { get; init; }
    public required DateTimeOffset ThisUpdate { get; init; }
    public required DateTimeOffset? NextUpdate { get; init; }
    private ReadOnlyMemory<byte> Entries { get; init; }
    private bool OnlyUsers { get; init; }
    private bool OnlyCas { get; init; }
    private bool Unusable { get; init; }

    public static CrlDocument? Parse(byte[] der)
    {
        try
        {
            var outer = new AsnReader(der, AsnEncodingRules.BER).ReadSequence();
            var tbsDer = outer.ReadEncodedValue();
            var algorithm = outer.ReadEncodedValue();
            var signature = outer.ReadBitString(out _);
            var tbs = new AsnReader(tbsDer, AsnEncodingRules.BER).ReadSequence();
            if (tbs.PeekTag().HasSameClassAndValue(Asn1Tag.Integer)) tbs.ReadEncodedValue();
            tbs.ReadEncodedValue(); // the signature's algorithm, again
            var issuer = tbs.ReadEncodedValue();
            var thisUpdate = ReadTime(tbs);
            DateTimeOffset? nextUpdate = null;
            if (tbs.HasData && (tbs.PeekTag().HasSameClassAndValue(Asn1Tag.UtcTime) || tbs.PeekTag().HasSameClassAndValue(Asn1Tag.GeneralizedTime)))
                nextUpdate = ReadTime(tbs);
            ReadOnlyMemory<byte> entries = default;
            if (tbs.HasData && tbs.PeekTag().HasSameClassAndValue(Asn1Tag.Sequence)) entries = tbs.ReadEncodedValue();
            bool onlyUsers = false, onlyCas = false, unusable = false;
            if (tbs.HasData && tbs.PeekTag().HasSameClassAndValue(new Asn1Tag(TagClass.ContextSpecific, 0)))
            {
                var exts = tbs.ReadSequence(new Asn1Tag(TagClass.ContextSpecific, 0, true)).ReadSequence();
                while (exts.HasData)
                {
                    var ext = exts.ReadSequence();
                    var oid = ext.ReadObjectIdentifier();
                    var critical = ext.PeekTag().HasSameClassAndValue(Asn1Tag.Boolean) && ext.ReadBoolean();
                    var value = ext.ReadOctetString();
                    if (oid == DeltaIndicatorOid) unusable = true; // a delta list says nothing alone
                    else if (oid == DistributionPointOid) ReadScope(value, ref onlyUsers, ref onlyCas, ref unusable);
                    else if (critical) unusable = true;
                }
            }
            return new CrlDocument
            {
                Der = der,
                Tbs = tbsDer.ToArray(),
                Algorithm = algorithm.ToArray(),
                Signature = signature,
                IssuerName = issuer.ToArray(),
                ThisUpdate = thisUpdate,
                NextUpdate = nextUpdate,
                Entries = entries,
                OnlyUsers = onlyUsers,
                OnlyCas = onlyCas,
                Unusable = unusable,
            };
        }
        catch (Exception ex) when (ex is AsnContentException or CryptographicException or ArgumentException or OverflowException)
        {
            return null;
        }
    }

    /// <summary>IssuingDistributionPoint: which certificates the list speaks for (attribute and indirect lists aren't used).</summary>
    private static void ReadScope(byte[] value, ref bool onlyUsers, ref bool onlyCas, ref bool unusable)
    {
        var idp = new AsnReader(value, AsnEncodingRules.BER).ReadSequence();
        while (idp.HasData)
        {
            var tag = idp.PeekTag();
            if (tag.TagClass != TagClass.ContextSpecific)
            {
                idp.ReadEncodedValue();
                continue;
            }
            switch (tag.TagValue)
            {
                case 1: onlyUsers = idp.ReadBoolean(new Asn1Tag(TagClass.ContextSpecific, 1)); break;
                case 2: onlyCas = idp.ReadBoolean(new Asn1Tag(TagClass.ContextSpecific, 2)); break;
                case 3: // only some reasons: can't vouch for a certificate alone
                    idp.ReadEncodedValue();
                    unusable = true;
                    break;
                case 4:
                    if (idp.ReadBoolean(new Asn1Tag(TagClass.ContextSpecific, 4))) unusable = true;
                    break;
                case 5:
                    if (idp.ReadBoolean(new Asn1Tag(TagClass.ContextSpecific, 5))) unusable = true;
                    break;
                default: idp.ReadEncodedValue(); break;
            }
        }
    }

    private static DateTimeOffset ReadTime(AsnReader r) =>
        r.PeekTag().HasSameClassAndValue(Asn1Tag.UtcTime) ? r.ReadUtcTime() : r.ReadGeneralizedTime();

    /// <summary>The list was issued by <paramref name="issuer"/>'s name and key, and speaks for <paramref name="cert"/>.</summary>
    public bool SpeaksFor(X509Certificate2 cert, X509Certificate2 issuer)
    {
        if (Unusable || !IssuerName.AsSpan().SequenceEqual(issuer.SubjectName.RawData)) return false;
        if (OnlyUsers || OnlyCas)
        {
            var ca = cert.Extensions.OfType<X509BasicConstraintsExtension>().FirstOrDefault()?.CertificateAuthority == true;
            if (OnlyUsers && ca) return false;
            if (OnlyCas && !ca) return false;
        }
        return DerSignature.Verify(issuer, Algorithm, Tbs, Signature);
    }

    /// <summary>When the list says <paramref name="cert"/> was revoked; null when it isn't listed (or was taken off hold).</summary>
    public DateTimeOffset? RevokedAt(X509Certificate2 cert)
    {
        if (Entries.IsEmpty) return null;
        var wanted = new BigInteger(Convert.FromHexString(cert.SerialNumber), isUnsigned: false, isBigEndian: true);
        try
        {
            var entries = new AsnReader(Entries, AsnEncodingRules.BER).ReadSequence();
            while (entries.HasData)
            {
                var entry = entries.ReadSequence();
                if (entry.ReadInteger() != wanted) continue;
                var at = ReadTime(entry);
                return RemovedFromHold(entry) ? null : at;
            }
        }
        catch (AsnContentException)
        {
            // The signature checked out, so the issuer wrote this; what can't be read says nothing.
        }
        return null;
    }

    private static bool RemovedFromHold(AsnReader entry)
    {
        if (!entry.HasData || !entry.PeekTag().HasSameClassAndValue(Asn1Tag.Sequence)) return false;
        var exts = entry.ReadSequence();
        while (exts.HasData)
        {
            var ext = exts.ReadSequence();
            if (ext.ReadObjectIdentifier() != "2.5.29.21") continue;
            if (ext.PeekTag().HasSameClassAndValue(Asn1Tag.Boolean)) ext.ReadBoolean();
            var reason = new AsnReader(ext.ReadOctetString(), AsnEncodingRules.BER).ReadEncodedValue();
            return reason.Length == 3 && reason.Span[2] == 8; // removeFromCRL
        }
        return false;
    }
}

/// <summary>What is known about one certificate's revocation.</summary>
internal enum RevocationAnswer
{
    /// <summary>No usable data.</summary>
    None,
    /// <summary>A verified response or list says it wasn't revoked at the time asked about.</summary>
    Good,
    /// <summary>A verified response or list says it was revoked at or before the time asked about.</summary>
    Revoked,
    /// <summary>A verified response or list says it was revoked, after the time asked about.</summary>
    RevokedLater,
    /// <summary>The responder doesn't know the certificate.</summary>
    Unknown,
    /// <summary>There is data, but too old to speak for the time asked about.</summary>
    Stale,
}

/// <summary>
/// The certificates, OCSP responses and CRLs a check may use: from the file's /DSS, a signature's own archived data, or
/// asked for online by the person. Everything in here came from the file or from a server that a file's certificate
/// named, so it is treated as hostile: sizes and counts are limited on the way in, nothing counts until its signature
/// checks out against the issuer of the certificate it speaks for, and a time budget ends the work on a file built to
/// make it long.
/// </summary>
internal sealed class RevocationPool
{
    public const int MaxCertBytes = 64 * 1024;
    public const int MaxOcspBytes = 256 * 1024;
    public const int MaxCrlBytes = 16 * 1024 * 1024;
    private const long MaxTotalBytes = 64 * 1024 * 1024;
    private const int MaxCerts = 256;
    private const int MaxResponses = 256;
    private const int MaxChecksPerCertificate = 8;

    private readonly List<X509Certificate2> _certs = [];
    private readonly HashSet<string> _certHashes = [];
    private readonly List<OcspResponse> _ocsps = [];
    private readonly List<CrlDocument> _crls = [];
    private readonly HashSet<string> _hashes = [];
    private readonly Dictionary<string, (RevocationAnswer, DateTimeOffset?, X509Certificate2?, byte[]?)> _memo = [];
    private readonly System.Diagnostics.Stopwatch _clock = System.Diagnostics.Stopwatch.StartNew();
    private long _bytes;

    /// <summary>How long one file's data may keep a check busy.</summary>
    private static readonly TimeSpan Budget = TimeSpan.FromSeconds(20);

    /// <summary>The file asked for more work than a check does, so what is reported isn't complete.</summary>
    public bool OutOfBudget => _clock.Elapsed > Budget;

    /// <summary>The budget is for this data, not for whatever else a large file took to read first.</summary>
    public void RestartBudget() => _clock.Restart();

    /// <summary>Data the limits or a parse left out.</summary>
    public int Skipped { get; private set; }

    public IReadOnlyList<X509Certificate2> Certs => _certs;
    public IReadOnlyList<OcspResponse> Ocsps => _ocsps;
    public IReadOnlyList<CrlDocument> Crls => _crls;

    public void AddCert(byte[] der)
    {
        _memo.Clear();
        if (der.Length > MaxCertBytes || _certs.Count >= MaxCerts)
        {
            Skipped++;
            return;
        }
        if (!_certHashes.Add(Convert.ToHexString(SHA256.HashData(der)))) return;
        try
        {
            _certs.Add(X509CertificateLoader.LoadCertificate(der));
        }
        catch (CryptographicException)
        {
            Skipped++;
        }
    }

    public void AddCert(X509Certificate2 cert) => AddCert(cert.RawData);

    public void AddOcsp(byte[] der)
    {
        if (!Room(der, MaxOcspBytes)) return;
        if (OcspResponse.Parse(der, out _) is { } r)
        {
            _ocsps.Add(r);
            foreach (var c in r.Certs) AddCert(c);
        }
        else Skipped++;
    }

    public void AddCrl(byte[] der)
    {
        if (!Room(der, MaxCrlBytes)) return;
        if (CrlDocument.Parse(der) is { } c) _crls.Add(c);
        else Skipped++;
    }

    private bool Room(byte[] der, int max)
    {
        _memo.Clear();
        if (der.Length > max || _ocsps.Count + _crls.Count >= MaxResponses || _bytes + der.Length > MaxTotalBytes)
        {
            Skipped++;
            return false;
        }
        if (!_hashes.Add(Convert.ToHexString(SHA256.HashData(der)))) return false;
        _bytes += der.Length;
        return true;
    }

    public void AddFrom(RevocationPool other)
    {
        foreach (var c in other._certs) AddCert(c);
        foreach (var o in other._ocsps) AddOcsp(o.Der);
        foreach (var c in other._crls) AddCrl(c.Der);
    }

    /// <summary>
    /// Reads Adobe's revocationInfoArchival value (a signed attribute many Acrobat-made signatures carry):
    /// [0] CRLs, [1] OCSP responses.
    /// </summary>
    public void AddArchival(byte[] value)
    {
        try
        {
            var seq = new AsnReader(value, AsnEncodingRules.BER).ReadSequence();
            while (seq.HasData)
            {
                var tag = seq.PeekTag();
                if (tag.TagClass != TagClass.ContextSpecific)
                {
                    seq.ReadEncodedValue();
                    continue;
                }
                if (tag.TagValue is 0 or 1)
                {
                    var items = seq.ReadSequence(new Asn1Tag(TagClass.ContextSpecific, tag.TagValue, true)).ReadSequence();
                    while (items.HasData)
                    {
                        var der = items.ReadEncodedValue().ToArray();
                        if (tag.TagValue == 0) AddCrl(der);
                        else AddOcsp(der);
                    }
                }
                else seq.ReadEncodedValue();
            }
        }
        catch (AsnContentException)
        {
            Skipped++;
        }
    }

    /// <summary>
    /// What the verified data says about <paramref name="cert"/> at <paramref name="when"/>; a revocation at or before that
    /// time, or after it, wins over any good answer. Also which responder answered, when one was delegated, and the data it came from.
    /// </summary>
    public (RevocationAnswer Answer, DateTimeOffset? RevokedAt, X509Certificate2? Responder, byte[]? Evidence) Check(X509Certificate2 cert, X509Certificate2 issuer, DateTimeOffset when)
    {
        var key = $"{cert.Thumbprint}|{issuer.Thumbprint}|{when.ToUnixTimeSeconds()}";
        if (_memo.TryGetValue(key, out var seen)) return seen;
        var result = CheckCore(cert, issuer, when);
        _memo[key] = result;
        return result;
    }

    private (RevocationAnswer, DateTimeOffset?, X509Certificate2?, byte[]?) CheckCore(X509Certificate2 cert, X509Certificate2 issuer, DateTimeOffset when)
    {
        var best = (Answer: RevocationAnswer.None, RevokedAt: (DateTimeOffset?)null, Responder: (X509Certificate2?)null, Evidence: (byte[]?)null);
        var now = DateTimeOffset.UtcNow.AddMinutes(5);
        var checks = 0;

        foreach (var r in _ocsps)
        {
            if (OutOfBudget || checks >= MaxChecksPerCertificate) break;
            if (r.AnswerFor(cert, issuer) is not { } a) continue;
            if (a.ThisUpdate > now || !r.SignedFor(issuer, _certs, out var responder)) continue;
            checks++; // only what verifies: forgeries can't use up the turns of a real answer (the time budget ends a file full of them)
            switch (a.Status)
            {
                case OcspCertStatus.Revoked:
                    if (a.RevokedAt is { } at && at > when) best = Rank(best, (RevocationAnswer.RevokedLater, at, responder, r.Der));
                    else return (RevocationAnswer.Revoked, a.RevokedAt, responder, r.Der);
                    break;
                case OcspCertStatus.Unknown:
                    best = Rank(best, (RevocationAnswer.Unknown, null, responder, r.Der));
                    break;
                default:
                    best = Rank(best, (Covers(a.ThisUpdate, a.NextUpdate, when) ? RevocationAnswer.Good : RevocationAnswer.Stale, null, responder, r.Der));
                    break;
            }
        }
        checks = 0;
        foreach (var c in _crls)
        {
            if (OutOfBudget || checks >= MaxChecksPerCertificate) break;
            if (!c.IssuerName.AsSpan().SequenceEqual(issuer.SubjectName.RawData)) continue;
            if (c.ThisUpdate > now || !c.SpeaksFor(cert, issuer)) continue;
            checks++;
            if (c.RevokedAt(cert) is { } at)
            {
                if (at > when) best = Rank(best, (RevocationAnswer.RevokedLater, at, null, c.Der));
                else return (RevocationAnswer.Revoked, at, null, c.Der);
            }
            else best = Rank(best, (Covers(c.ThisUpdate, c.NextUpdate, when) ? RevocationAnswer.Good : RevocationAnswer.Stale, null, null, c.Der));
        }
        return best;
    }

    /// <summary>The data was issued after the time asked about, or was still in force then.</summary>
    private static bool Covers(DateTimeOffset thisUpdate, DateTimeOffset? nextUpdate, DateTimeOffset when) =>
        thisUpdate >= when || nextUpdate is { } next && next >= when;

    private static (RevocationAnswer Answer, DateTimeOffset? RevokedAt, X509Certificate2? Responder, byte[]? Evidence) Rank(
        (RevocationAnswer Answer, DateTimeOffset? RevokedAt, X509Certificate2? Responder, byte[]? Evidence) a,
        (RevocationAnswer Answer, DateTimeOffset? RevokedAt, X509Certificate2? Responder, byte[]? Evidence) b)
    {
        static int Weight(RevocationAnswer x) => x switch
        {
            RevocationAnswer.RevokedLater => 4,
            RevocationAnswer.Good => 3,
            RevocationAnswer.Unknown => 2,
            RevocationAnswer.Stale => 1,
            _ => 0,
        };
        return Weight(b.Answer) > Weight(a.Answer) ? b : a;
    }

    /// <summary>
    /// The certificates in <paramref name="pool"/> that can be part of <paramref name="cert"/>'s chain (their subject is an
    /// issuer on the way up), so that a thousand unrelated or looping certificates in a hostile file never reach the chain builder.
    /// </summary>
    public static X509Certificate2Collection ChainCandidates(X509Certificate2 cert, IEnumerable<X509Certificate2> pool)
    {
        const int maxCandidates = 32;
        var result = new X509Certificate2Collection();
        var bySubject = pool.GroupBy(c => Convert.ToHexString(c.SubjectName.RawData)).ToDictionary(g => g.Key, g => g.Take(4).ToList());
        var names = new Queue<string>([Convert.ToHexString(cert.IssuerName.RawData)]);
        var seen = new HashSet<string>();
        while (names.Count > 0 && result.Count < maxCandidates)
        {
            var name = names.Dequeue();
            if (!seen.Add(name) || !bySubject.TryGetValue(name, out var found)) continue;
            foreach (var c in found)
            {
                result.Add(c);
                names.Enqueue(Convert.ToHexString(c.IssuerName.RawData));
            }
        }
        return result;
    }

    /// <summary>
    /// <paramref name="cert"/>'s chain as far as what is at hand and Windows' certificate stores reach, end certificate first.
    /// Never goes online: a chain build is the one thing that would otherwise follow addresses a file's certificates name.
    /// </summary>
    public static List<X509Certificate2> BuildChain(X509Certificate2 cert, IEnumerable<X509Certificate2> pool, DateTimeOffset? at = null, X509Certificate2Collection? anchors = null)
    {
        using var chain = new X509Chain();
        ForbidNetwork(chain);
        chain.ChainPolicy.ExtraStore.AddRange(ChainCandidates(cert, pool));
        if (at is { } t) chain.ChainPolicy.VerificationTime = t.LocalDateTime;
        if (anchors is not null)
        {
            chain.ChainPolicy.TrustMode = X509ChainTrustMode.CustomRootTrust;
            chain.ChainPolicy.CustomTrustStore.AddRange(anchors);
        }
        try
        {
            chain.Build(cert);
            return [.. chain.ChainElements.Select(e => X509CertificateLoader.LoadCertificate(e.Certificate.RawData))];
        }
        catch (Exception ex) when (ex is CryptographicException or ArgumentException)
        {
            return [X509CertificateLoader.LoadCertificate(cert.RawData)];
        }
        finally
        {
            foreach (var e in chain.ChainElements) e.Certificate.Dispose();
        }
    }

    /// <summary>No revocation lookups and no fetching of missing issuers: nothing in a chain build may contact an address a certificate names.</summary>
    internal static void ForbidNetwork(X509Chain chain)
    {
        chain.ChainPolicy.RevocationMode = X509RevocationMode.NoCheck;
        chain.ChainPolicy.DisableCertificateDownloads = true;
    }
}
