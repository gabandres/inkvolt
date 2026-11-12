using System.Security.Cryptography;
using System.Security.Cryptography.Pkcs;
using System.Security.Cryptography.X509Certificates;
using PdfSharp.Pdf.IO;

namespace InkvoltPdf.Core;

/// <summary>The PAdES baseline level a signature in a file reaches (ETSI EN 319 142-1), as this app judges it.</summary>
public enum PadesLevel
{
    /// <summary>Not a PAdES baseline signature (e.g. adbe.pkcs7.detached), or a document timestamp.</summary>
    None,
    /// <summary>The signature alone.</summary>
    BB,
    /// <summary>A timestamp proves it existed at a time.</summary>
    BT,
    /// <summary>And the file holds the validation data for its certificates and the timestamp's.</summary>
    BLT,
    /// <summary>And a document timestamp covers that data, so it can be renewed before the algorithms age.</summary>
    BLTA,
}

/// <summary>What the data in hand says about one certificate in a chain.</summary>
public enum CertificateCheckOutcome
{
    /// <summary>A self-signed root: nobody else can vouch for it.</summary>
    Root,
    /// <summary>An OCSP responder its issuer says needn't be checked.</summary>
    NoCheckNeeded,
    Good,
    Revoked,
    /// <summary>Revoked after the time that counts, so it doesn't touch a signature made before.</summary>
    RevokedLater,
    /// <summary>The responder doesn't know this certificate.</summary>
    Unknown,
    /// <summary>The data in hand is too old to speak for the signing time.</summary>
    Stale,
    /// <summary>No data for it in the file, or none that verifies.</summary>
    NoData,
    /// <summary>Its issuer isn't in the file or on this PC, so nothing about it can be verified.</summary>
    NoIssuer,
}

/// <summary>One certificate of a chain and what is known about it.</summary>
public sealed record CertificateCheck(string Name, CertificateCheckOutcome Outcome, DateTimeOffset? RevokedAt = null)
{
    internal bool Covered => Outcome is CertificateCheckOutcome.Root or CertificateCheckOutcome.NoCheckNeeded or CertificateCheckOutcome.Good or CertificateCheckOutcome.RevokedLater;
}

/// <summary>What a file holds for checking one signature in the long term.</summary>
/// <param name="Level">The PAdES level reached.</param>
/// <param name="DataComplete">Every certificate of the signature's chain (and its timestamp's) has verified revocation data in hand.</param>
/// <param name="Chain">The signer's chain, then its timestamp authority's, as far as they could be built.</param>
/// <param name="Summary">One or two sentences for the person.</param>
/// <param name="OnlyValidationDataAfter">The updates after this signature hold only long-term data and document timestamps.</param>
public sealed record LongTermInfo(PadesLevel Level, bool DataComplete, IReadOnlyList<CertificateCheck> Chain, string Summary, bool OnlyValidationDataAfter = false);

/// <summary>Revocation data asked for online, for one check of the file. Nothing of it is written anywhere.</summary>
public sealed class RevocationSnapshot
{
    internal RevocationPool Pool { get; } = new();
}

/// <summary>What checking one signature field found, beyond what the app shows.</summary>
internal sealed class SignatureFacts(SignatureInfo info)
{
    public SignatureInfo Info { get; set; } = info;

    /// <summary>Where the signed bytes end: the revision the signature belongs to.</summary>
    public long End { get; init; }

    /// <summary>The bytes whose SHA-1 is this signature's /VRI key.</summary>
    public byte[]? ContentsForVri { get; init; }

    public bool DocumentTimestamp { get; init; }
    public SignerInfo? Signer { get; init; }
    public X509Certificate2Collection Certs { get; init; } = [];
    public X509Certificate2? Tsa { get; init; }
    public X509Certificate2Collection TsaCerts { get; init; } = [];
    public DateTimeOffset? Stamped { get; init; }
    public DateTimeOffset? TrustTime { get; init; }
    public bool IsPades { get; init; }
    public bool OnlyValidationDataAfter { get; set; }

    /// <summary>The signature checked out, whatever came later.</summary>
    public bool Intact => Info.Status is SignatureStatus.Valid or SignatureStatus.ModifiedAfterSigning;

    public string VriKey => Convert.ToHexString(SHA1.HashData(ContentsForVri ?? []));

    /// <summary>
    /// The time a trusted timestamp vouches for (a document timestamp's own, when its authority is trusted); null when no
    /// trusted authority says when: a token anyone can put in a file proves nothing about the long term.
    /// </summary>
    public DateTimeOffset? VouchedTime => DocumentTimestamp ? (Info.CertificateTrusted ? Stamped : null) : TrustTime;
}

/// <summary>
/// Judges each signature from what the file holds, and from nothing else: its chain against the /DSS and the signature's
/// own archived revocation data, the level it reaches, and a revocation found there takes away the trust. Goes nowhere online.
/// </summary>
internal static class LongTermCheck
{
    /// <summary>Adobe's signed attribute for revocation data taken at signing.</summary>
    private const string RevocationArchivalOid = "1.2.840.113583.1.1.8";

    /// <summary>How many document timestamps a file is looked at under: each means reading a revision again.</summary>
    private const int MaxStampsRead = 3;

    public static void Apply(byte[] data, string? password, List<SignatureFacts> all, RevocationPool pool, X509Certificate2Collection? anchors)
    {
        pool.RestartBudget();
        foreach (var f in all.Where(f => f.Intact))
        {
            foreach (var c in f.Certs) pool.AddCert(c);
            foreach (var c in f.TsaCerts) pool.AddCert(c);
            AddArchived(f.Signer, pool);
        }
        var revisions = new Dictionary<long, RevocationPool>();
        // Document timestamps first: whether each one's authority stays trusted decides whether it speaks for a time for the
        // signatures under it, whatever order the form lists them in.
        var ordered = all.Where(f => f.Intact && f.DocumentTimestamp).Concat(all.Where(f => f.Intact && !f.DocumentTimestamp)).ToList();
        List<SignatureFacts> stamps = [];

        foreach (var f in ordered)
        {
            // Only document timestamps a trusted authority made speak for a time.
            if (!f.DocumentTimestamp && stamps.Count == 0)
                stamps = [.. all.Where(s => s.Intact && s.DocumentTimestamp && s.VouchedTime is not null).OrderBy(s => s.End)];
            if (f.Info.Certificate is not { } cert) continue;
            if (pool.OutOfBudget)
            {
                OutOfBudget(f, pool);
                continue;
            }
            var firstStamp = stamps.FirstOrDefault(s => s.End > f.End);
            var when = f.VouchedTime ?? firstStamp?.VouchedTime ?? DateTimeOffset.UtcNow;
            var chain = Walk(cert, pool, when, anchors);
            var tsa = f.DocumentTimestamp ? null : f.VouchedTime is not null ? f.Tsa : firstStamp?.Tsa;
            var tsaChain = tsa is null ? [] : Walk(tsa, pool, when, anchors);
            var complete = chain.All(c => c.Covered) && tsaChain.All(c => c.Covered);

            // Revocation takes away the trust at the time that counts for trust: a trusted timestamp's, else now.
            var trustAt = f.TrustTime ?? DateTimeOffset.UtcNow;
            var atTrust = f.TrustTime is { } t && t == when ? chain : Walk(cert, pool, trustAt, anchors);
            var revoked = atTrust.FirstOrDefault(c => c.Outcome == CertificateCheckOutcome.Revoked);
            if (revoked is not null)
                f.Info = f.Info with
                {
                    CertificateTrusted = false,
                    CertificateStatus = revoked.RevokedAt is { } at ? Loc.Format(PdfStrings.Ltv_RevokedStatusAt, at.UtcDateTime, revoked.Name) : Loc.Format(PdfStrings.Ltv_RevokedStatus, revoked.Name),
                };

            var level = Level(data, password, f, stamps, pool, revisions, complete, anchors);
            f.Info = f.Info with
            {
                LongTerm = new LongTermInfo(level, complete, [.. chain, .. tsaChain], Summary(f, level, complete, chain.Concat(tsaChain).ToList(), pool), f.OnlyValidationDataAfter),
            };
            if (pool.OutOfBudget) OutOfBudget(f, pool);
        }
    }

    /// <summary>
    /// A file that makes the check run out of time never leaves a certificate trusted: what it held wasn't all judged, and a
    /// revocation among it could have been missed. A reason it is already untrusted for (a revocation, an untrusted root)
    /// is the one shown.
    /// </summary>
    private static void OutOfBudget(SignatureFacts f, RevocationPool pool)
    {
        f.Info = f.Info with { LongTerm = new LongTermInfo(PadesLevel.None, false, [], Summary(f, PadesLevel.None, false, [], pool), f.OnlyValidationDataAfter) };
        if (f.Info.CertificateTrusted) f.Info = f.Info with { CertificateTrusted = false, CertificateStatus = PdfStrings.Ltv_OutOfBudget };
    }

    private static PadesLevel Level(byte[] data, string? password, SignatureFacts f, List<SignatureFacts> stamps, RevocationPool pool,
        Dictionary<long, RevocationPool> revisions, bool complete, X509Certificate2Collection? anchors)
    {
        if (f.DocumentTimestamp || !f.IsPades) return PadesLevel.None;
        var later = stamps.Where(s => s.End > f.End).ToList();
        if (f.VouchedTime is null && later.Count == 0) return PadesLevel.BB;
        if (!complete) return PadesLevel.BT;
        // B-LTA: a document timestamp over this signature's data. A signature without a timestamp of its own has its time
        // from the first document timestamp, which is then its B-T: it takes one more.
        var over = f.VouchedTime is null ? later.Skip(1).ToList() : later;
        var tsa = f.VouchedTime is not null ? f.Tsa : later.FirstOrDefault()?.Tsa;
        foreach (var stamp in Enumerable.Reverse(over).Take(MaxStampsRead))
        {
            if (!revisions.TryGetValue(stamp.End, out var revision))
            {
                revision = RevisionPool(data, stamp.End, password, pool);
                revisions[stamp.End] = revision;
            }
            var when = f.VouchedTime ?? later[0].VouchedTime ?? DateTimeOffset.UtcNow;
            var covered = Walk(f.Info.Certificate!, revision, when, anchors).All(c => c.Covered)
                          && (tsa is null || Walk(tsa, revision, when, anchors).All(c => c.Covered));
            if (revision.OutOfBudget) break; // what wasn't all judged covers nothing
            if (covered) return PadesLevel.BLTA;
        }
        return PadesLevel.BLT;
    }

    /// <summary>What the file up to a timestamp held, plus the signatures' own certificates.</summary>
    private static RevocationPool RevisionPool(byte[] data, long end, string? password, RevocationPool whole)
    {
        var revision = new RevocationPool();
        revision.ShareBudget(whole); // reading the revision's store and judging it count against the file's time too
        foreach (var c in whole.Certs) revision.AddCert(c);
        try
        {
            using var doc = PdfObj.Open(data.AsSpan(0, (int)end).ToArray(), password, PdfDocumentOpenMode.Import);
            Dss.ReadInto(doc, revision);
        }
        catch (Exception ex) when (ex is not OutOfMemoryException)
        {
            // A revision that can't be read holds nothing.
        }
        return revision;
    }

    /// <summary>What the pool says about each certificate of <paramref name="cert"/>'s chain at <paramref name="when"/>, responders included.</summary>
    private static List<CertificateCheck> Walk(X509Certificate2 cert, RevocationPool pool, DateTimeOffset when, X509Certificate2Collection? anchors)
    {
        var result = new List<CertificateCheck>();
        var seen = new HashSet<string>();
        var chain = RevocationPool.BuildChain(cert, pool.Certs, when, anchors);
        for (var i = 0; i < chain.Count; i++)
        {
            var c = chain[i];
            var issuer = i + 1 < chain.Count ? chain[i + 1] : null;
            Judge(c, issuer, pool, when, result, seen, depth: 0);
        }
        return result;
    }

    private static void Judge(X509Certificate2 c, X509Certificate2? issuer, RevocationPool pool, DateTimeOffset when, List<CertificateCheck> result, HashSet<string> seen, int depth)
    {
        if (!seen.Add(c.Thumbprint)) return;
        var name = CertFacts.Name(c);
        if (CertFacts.IsSelfSigned(c))
        {
            result.Add(new CertificateCheck(name, CertificateCheckOutcome.Root));
            return;
        }
        if (issuer is null)
        {
            result.Add(new CertificateCheck(name, CertificateCheckOutcome.NoIssuer));
            return;
        }
        if (CertFacts.IsNoCheckResponder(c))
        {
            result.Add(new CertificateCheck(name, CertificateCheckOutcome.NoCheckNeeded));
            return;
        }
        var (answer, at, responder, _) = pool.Check(c, issuer, when);
        result.Add(new CertificateCheck(name, answer switch
        {
            RevocationAnswer.Good => CertificateCheckOutcome.Good,
            RevocationAnswer.Revoked => CertificateCheckOutcome.Revoked,
            RevocationAnswer.RevokedLater => CertificateCheckOutcome.RevokedLater,
            RevocationAnswer.Unknown => CertificateCheckOutcome.Unknown,
            RevocationAnswer.Stale => CertificateCheckOutcome.Stale,
            _ => CertificateCheckOutcome.NoData,
        }, at));
        // A delegated responder is a certificate the answer leans on: it needs its own data, unless it says it doesn't.
        if (responder is not null && depth < 3) Judge(responder, issuer, pool, when, result, seen, depth + 1);
    }

    private static void AddArchived(SignerInfo? si, RevocationPool pool)
    {
        if (si is null) return;
        foreach (var attr in si.SignedAttributes)
            if (attr.Oid.Value == RevocationArchivalOid && attr.Values.Count > 0)
                pool.AddArchival(attr.Values[0].RawData);
    }

    private static string Summary(SignatureFacts f, PadesLevel level, bool complete, IReadOnlyList<CertificateCheck> chain, RevocationPool pool)
    {
        if (pool.OutOfBudget) return PdfStrings.Ltv_OutOfBudget;
        var missing = chain.Where(c => !c.Covered).Select(c => c.Name).Distinct().ToList();
        var which = missing.Count == 0 ? "" : Loc.Format(missing.Count > 3 ? PdfStrings.Ltv_MissingForMore : PdfStrings.Ltv_MissingFor, string.Join(", ", missing.Take(3)));
        var later = chain.FirstOrDefault(c => c.Outcome == CertificateCheckOutcome.RevokedLater);
        var note = later is null ? "" : Loc.Format(PdfStrings.Ltv_RevokedLaterNote, later.Name, later.RevokedAt);
        if (f.DocumentTimestamp)
            return (complete ? PdfStrings.Ltv_DocTsComplete : Loc.Format(PdfStrings.Ltv_DocTsIncomplete, which)) + note;
        return (level switch
        {
            PadesLevel.BLTA => PdfStrings.Ltv_BLta,
            PadesLevel.BLT => PdfStrings.Ltv_BLt,
            PadesLevel.BT => Loc.Format(PdfStrings.Ltv_Bt, which),
            PadesLevel.BB when complete => PdfStrings.Ltv_BbComplete,
            PadesLevel.BB => PdfStrings.Ltv_BbNothing,
            _ when complete && f.VouchedTime is not null => PdfStrings.Ltv_NotPadesComplete,
            _ => Loc.Format(PdfStrings.Ltv_NotPades, which),
        }) + note;
    }
}
