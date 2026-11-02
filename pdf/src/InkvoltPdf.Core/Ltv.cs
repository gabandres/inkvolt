using System.Security.Cryptography;
using System.Security.Cryptography.Pkcs;
using System.Security.Cryptography.X509Certificates;

namespace InkvoltPdf.Core;

/// <summary>How far signing goes beyond the signature itself.</summary>
public enum LongTermLevel
{
    /// <summary>Just the signature (and its timestamp, when asked).</summary>
    None,
    /// <summary>PAdES B-LT: with the revocation data for the whole chain in the file. Takes a signature timestamp.</summary>
    Lt,
    /// <summary>PAdES B-LTA: and a document timestamp over it all.</summary>
    Lta,
}

/// <summary>One address a certificate names, or the timestamp server, and what asking it involves.</summary>
/// <param name="ForWhom">The certificate it would be asked about.</param>
/// <param name="RefusedBecause">Why it won't be contacted, whatever is decided; null when it may be.</param>
public sealed record LtvAddress(LtvAddressKind Kind, string Url, string ForWhom, string? RefusedBecause);

/// <summary>What would go online, worked out without going online.</summary>
/// <param name="Addresses">Each once.</param>
/// <param name="Notes">What else to know (signatures left out, certificates that name no address).</param>
/// <param name="Complete">The file already holds everything: nothing needs asking.</param>
public sealed record LtvPlan(IReadOnlyList<LtvAddress> Addresses, IReadOnlyList<string> Notes, bool Complete)
{
    /// <summary>
    /// The server the timestamp field starts with, until the person enters another: free, answers over https (checked
    /// 2026-10-31; DigiCert's, SSL.com's and GlobalSign's answer only over http). Nothing is sent unless they ask for a timestamp.
    /// </summary>
    public const string SuggestedTimestampServer = "https://timestamp.sectigo.com";

    /// <summary>A plain line for each kind of address: what the far end gets.</summary>
    public static string WhatIsSent(LtvAddressKind kind) => kind switch
    {
        LtvAddressKind.Ocsp => "is told which certificate is being asked about (its serial number and a hash of its issuer)",
        LtvAddressKind.Crl => "sends its list of revoked certificates; nothing but the request is sent",
        LtvAddressKind.Issuer => "sends a public certificate; nothing but the request is sent",
        _ => "receives a hash of the document or signature, never the document",
    };
}

/// <summary>What became of one certificate.</summary>
public sealed record LtvCertificateResult(string Name, string Outcome, bool Covered);

/// <summary>The outcome of adding long-term data.</summary>
/// <param name="Pdf">The file with the update appended (the same bytes when there was nothing to add).</param>
/// <param name="Changed">Whether anything was appended.</param>
/// <param name="Certificates">Each certificate looked at, and what became of it.</param>
/// <param name="Contacts">What was actually asked.</param>
public sealed record LtvResult(byte[] Pdf, bool Changed, IReadOnlyList<LtvCertificateResult> Certificates, IReadOnlyList<LtvContact> Contacts);

/// <summary>The outcome of asking online about a file's certificates, which leaves the file alone.</summary>
public sealed record LtvOnlineResult(RevocationSnapshot Snapshot, IReadOnlyList<LtvCertificateResult> Certificates, IReadOnlyList<LtvContact> Contacts, string? Problem);

/// <summary>
/// Long-term validation: gets the revocation data for a signature's whole chain from the addresses its certificates name,
/// stores it in the file (<see cref="Dss"/>) as an incremental update, and can add a document timestamp over it. All of it
/// happens in memory: whatever fails, the caller has the bytes it started with. Going online happens only here and only
/// through <see cref="LtvClient"/>; <see cref="Plan"/> says beforehand where it would go.
/// </summary>
public static class Ltv
{
    /// <summary>What adding long-term data to <paramref name="data"/> would contact. Stays offline.</summary>
    /// <param name="client">The client that would go; addresses are judged as it would judge them.</param>
    /// <param name="onlyMissing">Leave out what the file already holds the answer to (false: what a check online would ask).</param>
    public static LtvPlan Plan(byte[] data, string? password = null, LtvClient? client = null, bool onlyMissing = true)
    {
        var facts = Signatures.Inspect(data, password);
        var pool = onlyMissing ? StoredPool(data, password) : new RevocationPool();
        var builder = new PlanBuilder(pool, client);
        var notes = new List<string>();
        foreach (var f in facts.Where(f => f.Intact && f.Info.Certificate is not null))
        {
            builder.AddChain(f.Info.Certificate!, f.Certs, f.Stamped ?? DateTimeOffset.UtcNow);
            if (f.Tsa is { } tsa) builder.AddChain(tsa, f.TsaCerts, f.Stamped ?? DateTimeOffset.UtcNow);
        }
        var broken = facts.Count(f => f.Info.Status is SignatureStatus.Invalid or SignatureStatus.DisallowedChanges or SignatureStatus.Unsupported);
        if (broken > 0) notes.Add($"{broken} signature{(broken == 1 ? "" : "s")} that didn't check out {(broken == 1 ? "is" : "are")} left out.");
        return new LtvPlan(builder.Addresses, [.. notes, .. builder.Notes], builder.Addresses.Count == 0 && builder.Notes.Count == 0);
    }

    /// <summary>What signing with <paramref name="signer"/> for the long term would contact, the timestamp server included. Stays offline.</summary>
    public static LtvPlan Plan(X509Certificate2 signer, string timestampUrl, LtvClient? client = null)
    {
        var builder = new PlanBuilder(new RevocationPool(), client);
        builder.AddChain(signer, [], DateTimeOffset.UtcNow);
        var list = new List<LtvAddress>
        {
            new(LtvAddressKind.Timestamp, timestampUrl, "the signature", client?.Why(timestampUrl, LtvAddressKind.Timestamp) ?? (client is null ? LtvClient.WhyRefused(timestampUrl, LtvAddressKind.Timestamp) : null)),
        };
        list.AddRange(builder.Addresses);
        var notes = new List<string>(builder.Notes)
        {
            "The timestamp's certificate names addresses of its own, of the same kinds; they are asked too, once the timestamp arrives.",
        };
        return new LtvPlan(list, notes, false);
    }

    private sealed class PlanBuilder(RevocationPool pool, LtvClient? client)
    {
        private readonly HashSet<string> _urls = [];
        private readonly HashSet<string> _seen = [];
        public List<LtvAddress> Addresses { get; } = [];
        public List<string> Notes { get; } = [];

        public void AddChain(X509Certificate2 cert, X509Certificate2Collection extra, DateTimeOffset when)
        {
            var chain = RevocationPool.BuildChain(cert, [.. extra.Cast<X509Certificate2>(), .. pool.Certs], when);
            for (var i = 0; i < chain.Count; i++)
            {
                var c = chain[i];
                if (!_seen.Add(c.Thumbprint) || CertFacts.IsSelfSigned(c) || CertFacts.HasOcspNoCheck(c)) continue;
                var issuer = i + 1 < chain.Count ? chain[i + 1] : null;
                var name = CertFacts.Name(c);
                if (issuer is null)
                {
                    foreach (var url in CertFacts.IssuerUrls(c)) Add(LtvAddressKind.Issuer, url, name);
                    Notes.Add($"{name}'s issuer isn't in the file or on this PC. If it can be fetched, the addresses it names are asked too.");
                }
                else if (pool.Check(c, issuer, when).Answer is RevocationAnswer.Good or RevocationAnswer.Revoked or RevocationAnswer.RevokedLater) continue;
                var ocsp = CertFacts.OcspUrls(c);
                var crl = CertFacts.CrlUrls(c);
                foreach (var url in ocsp) Add(LtvAddressKind.Ocsp, url, name);
                foreach (var url in crl) Add(LtvAddressKind.Crl, url, name);
                if (ocsp.Count == 0 && crl.Count == 0) Notes.Add($"{name} names no address to ask about it, so it can't be covered.");
            }
        }

        private void Add(LtvAddressKind kind, string url, string name)
        {
            if (_urls.Add(url)) Addresses.Add(new LtvAddress(kind, url, name, client is null ? LtvClient.WhyRefused(url, kind) : client.Why(url, kind)));
        }
    }

    /// <summary>
    /// Add Verification Information: asks for what the file lacks and stores it as an incremental update, leaving every
    /// signature as it was. A certificate that names no address, or only ones that are refused, is reported and left
    /// uncovered; a server that can't be reached ends it all with an error, and nothing is changed.
    /// </summary>
    /// <param name="documentTimestamp">Adds a document timestamp over it all, with this exchange (<see cref="LtvClient.TimestampSender"/>).</param>
    public static Task<LtvResult> AddVerificationAsync(byte[] data, string? password, LtvClient client, Func<byte[], CancellationToken, Task<byte[]>>? documentTimestamp = null, CancellationToken cancel = default) =>
        ExtendAsync(data, password, client, documentTimestamp, strict: false, cancel);

    /// <summary>Asks online about the certificates of a file's signatures, without changing the file: for <see cref="Signatures.Verify(byte[], string?, RevocationSnapshot?)"/>.</summary>
    public static async Task<LtvOnlineResult> CheckOnlineAsync(byte[] data, string? password, LtvClient client, CancellationToken cancel = default)
    {
        var facts = Signatures.Inspect(data, password);
        var gather = new Gatherer(client, new RevocationPool(), useStored: false);
        foreach (var f in facts.Where(f => f.Intact && f.Info.Certificate is not null)) // as Plan: what the person was shown is all that is asked
        {
            await gather.CoverChain(f.Info.Certificate!, f.Certs, DateTimeOffset.UtcNow, cancel).ConfigureAwait(false);
            if (f.Tsa is { } tsa) await gather.CoverChain(tsa, f.TsaCerts, f.Stamped ?? DateTimeOffset.UtcNow, cancel).ConfigureAwait(false);
        }
        var snapshot = new RevocationSnapshot();
        snapshot.Pool.AddFrom(gather.Pool);
        return new LtvOnlineResult(snapshot, gather.Results(), client.Contacts, gather.FirstFailure);
    }

    /// <summary>The whole job. <paramref name="strict"/>: for signing, where a promise of B-LT can't be kept with a gap in it.</summary>
    internal static async Task<LtvResult> ExtendAsync(byte[] data, string? password, LtvClient client, Func<byte[], CancellationToken, Task<byte[]>>? documentTimestamp, bool strict, CancellationToken cancel)
    {
        if (data.AsSpan().IndexOf("/Encrypt"u8) >= 0)
            throw new SigningException("Encrypted (password-protected) PDFs can't take long-term data, since an update can't be appended to them without breaking their signatures. Nothing was changed.");
        var before = Signatures.Inspect(data, password);
        var intact = before.Where(f => f.Intact && f.Info.Certificate is not null).ToList();
        if (intact.Count == 0)
            throw new SigningException(before.Any(f => f.Info.Status != SignatureStatus.Unsigned)
                ? "None of this document's signatures checks out, so there is nothing to add long-term data for. Nothing was changed."
                : "This document isn't signed, so there is nothing to add long-term data for.");

        // A signature with no timestamp yet gets its time from a first document timestamp (its B-T); the data then comes
        // after that time, so it can speak for it, and the timestamp below goes over the data (B-LTA).
        var output = data;
        var changed = false;
        if (documentTimestamp is not null && intact.Any(f => !f.DocumentTimestamp && f.Stamped is null && !before.Any(s => s.DocumentTimestamp && s.Intact && s.End > f.End)))
        {
            output = await Signing.AddDocumentTimestampAsync(output, password, documentTimestamp, cancel).ConfigureAwait(false);
            changed = true;
            intact = [.. Signatures.Inspect(output, password).Where(f => f.Intact && f.Info.Certificate is not null)];
        }

        var gather = new Gatherer(client, StoredPool(output, password), useStored: true);
        var entries = new List<VriEntry>();
        foreach (var f in intact) entries.Add(await gather.EntryFor(f, cancel).ConfigureAwait(false));
        Stop(gather, strict);

        if (!Dss.Holds(output, password, entries))
        {
            output = Dss.Append(output, password, entries);
            changed = true;
        }
        if (documentTimestamp is not null)
        {
            output = await Signing.AddDocumentTimestampAsync(output, password, documentTimestamp, cancel).ConfigureAwait(false);
            changed = true;
            // The stamp's own authority, so the timestamp can be checked later too.
            var stamp = Signatures.Inspect(output, password).Where(f => f.DocumentTimestamp && f.Intact).MaxBy(f => f.End)
                ?? throw new SigningException("The document timestamp doesn't check out. Nothing was changed.");
            var entry = await gather.EntryFor(stamp, cancel).ConfigureAwait(false);
            Stop(gather, strict);
            output = Dss.Append(output, password, [entry]);
        }

        // Whatever happened above, no signature may have suffered for it.
        if (changed)
        {
            var after = Signatures.Inspect(output, password);
            foreach (var f in before.Where(f => f.Intact))
                if (after.FirstOrDefault(a => a.Info.FieldName == f.Info.FieldName) is not { Intact: true })
                    throw new SigningException($"Adding long-term data would have broken the signature \"{f.Info.FieldName}\". Nothing was changed.");
        }
        return new LtvResult(output, changed, gather.Results(), client.Contacts);
    }

    private static void Stop(Gatherer gather, bool strict)
    {
        if (gather.FirstFailure is { } failure) throw new SigningException($"{failure} Nothing was changed.");
        if (!strict) return;
        var revoked = gather.Entries.FirstOrDefault(e => e.Outcome == CertificateCheckOutcome.Revoked);
        if (revoked is not null) throw new SigningException($"{CertFacts.Name(revoked.Cert)} has been revoked, so it can't sign for the long term. Nothing was changed.");
        var gap = gather.Entries.FirstOrDefault(e => !new CertificateCheck("", e.Outcome).Covered);
        if (gap is not null) throw new SigningException($"Long-term data can't be complete: {gap.Detail}. Sign without long-term validation, or use a digital ID whose authority can be asked. Nothing was changed.");
    }

    private static RevocationPool StoredPool(byte[] data, string? password)
    {
        var pool = new RevocationPool();
        try
        {
            using var doc = PdfObj.Open(data, password, PdfSharp.Pdf.IO.PdfDocumentOpenMode.Import);
            Dss.ReadInto(doc, pool);
        }
        catch (Exception ex) when (ex is not OutOfMemoryException)
        {
            // Nothing to build on: everything is asked for.
        }
        return pool;
    }

    /// <summary>Walks chains and asks for what is missing, one certificate at a time, each at most once.</summary>
    private sealed class Gatherer(LtvClient client, RevocationPool pool, bool useStored)
    {
        public sealed class Entry(X509Certificate2 cert)
        {
            public X509Certificate2 Cert { get; } = cert;
            public X509Certificate2? Responder { get; set; }
            public byte[]? Ocsp { get; set; }
            public byte[]? Crl { get; set; }
            public CertificateCheckOutcome Outcome { get; set; } = CertificateCheckOutcome.NoData;
            public string Detail { get; set; } = "";
        }

        private readonly Dictionary<string, Entry> _entries = [];
        public RevocationPool Pool { get; } = pool;
        public string? FirstFailure { get; private set; }
        public IEnumerable<Entry> Entries => _entries.Values;

        public IReadOnlyList<LtvCertificateResult> Results() =>
            [.. _entries.Values.Select(e => new LtvCertificateResult(CertFacts.Name(e.Cert), e.Detail, new CertificateCheck("", e.Outcome).Covered))];

        /// <summary>Covers a signature's chain and its timestamp's, and says what of it is this signature's.</summary>
        public async Task<VriEntry> EntryFor(SignatureFacts f, CancellationToken cancel)
        {
            var when = f.Stamped ?? DateTimeOffset.UtcNow;
            var used = await CoverChain(f.Info.Certificate!, f.Certs, when, cancel).ConfigureAwait(false);
            if (f.Tsa is { } tsa && !ReferenceEquals(tsa, f.Info.Certificate))
                used.AddRange(await CoverChain(tsa, f.TsaCerts, when, cancel).ConfigureAwait(false));
            var certs = used.Select(e => e.Cert.RawData).Concat(used.Where(e => e.Responder is not null).Select(e => e.Responder!.RawData)).ToList();
            return new VriEntry(f.VriKey, Distinct(certs), Distinct(used.Where(e => e.Ocsp is not null).Select(e => e.Ocsp!)), Distinct(used.Where(e => e.Crl is not null).Select(e => e.Crl!)));
        }

        private static List<byte[]> Distinct(IEnumerable<byte[]> items)
        {
            var seen = new HashSet<string>();
            return [.. items.Where(i => seen.Add(Convert.ToHexString(SHA256.HashData(i))))];
        }

        public async Task<List<Entry>> CoverChain(X509Certificate2 cert, IEnumerable<X509Certificate2> extra, DateTimeOffset when, CancellationToken cancel)
        {
            foreach (var c in extra) Pool.AddCert(c);
            var chain = await ChainWithIssuers(cert, when, cancel).ConfigureAwait(false);
            var used = new List<Entry>();
            for (var i = 0; i < chain.Count; i++)
                await Cover(chain[i], i + 1 < chain.Count ? chain[i + 1] : null, when, used, cancel).ConfigureAwait(false);
            return used;
        }

        /// <summary>The chain, fetching a missing issuer from the address its certificate names: only when the certificate before it checks out against it.</summary>
        private async Task<List<X509Certificate2>> ChainWithIssuers(X509Certificate2 cert, DateTimeOffset when, CancellationToken cancel)
        {
            const int maxFetches = 4;
            var chain = RevocationPool.BuildChain(cert, Pool.Certs, when);
            for (var fetch = 0; fetch < maxFetches && !CertFacts.IsSelfSigned(chain[^1]); fetch++)
            {
                var last = chain[^1];
                X509Certificate2? issuer = null;
                string? failure = null;
                foreach (var url in CertFacts.IssuerUrls(last))
                {
                    if (client.Refuses(url, LtvAddressKind.Issuer)) continue;
                    try
                    {
                        var bytes = await client.GetAsync(url, LtvAddressKind.Issuer, LtvClient.MaxCertificateReply, cancel).ConfigureAwait(false);
                        issuer = ReadCertificates(bytes).FirstOrDefault(c => CertFacts.SignedBy(last, c));
                        if (issuer is not null) break;
                    }
                    catch (LtvFetchException ex)
                    {
                        failure ??= ex.Message;
                    }
                }
                if (issuer is null)
                {
                    FirstFailure ??= failure;
                    break;
                }
                Pool.AddCert(issuer);
                chain = RevocationPool.BuildChain(cert, Pool.Certs, when);
                if (!chain.Any(c => c.Thumbprint == issuer.Thumbprint)) break;
            }
            return chain;
        }

        /// <summary>A certificate reply is one DER certificate, or a .p7c bundle of them.</summary>
        private static List<X509Certificate2> ReadCertificates(byte[] bytes)
        {
            try
            {
                return [X509CertificateLoader.LoadCertificate(bytes)];
            }
            catch (CryptographicException)
            {
                try
                {
                    var cms = new SignedCms();
                    cms.Decode(bytes);
                    return [.. cms.Certificates.Cast<X509Certificate2>().Take(8)];
                }
                catch (CryptographicException)
                {
                    return [];
                }
            }
        }

        private async Task Cover(X509Certificate2 c, X509Certificate2? issuer, DateTimeOffset when, List<Entry> used, CancellationToken cancel)
        {
            if (_entries.TryGetValue(c.Thumbprint, out var known))
            {
                used.Add(known);
                if (known.Responder is { } r && _entries.TryGetValue(r.Thumbprint, out var re)) used.Add(re);
                return;
            }
            var e = new Entry(c);
            _entries[c.Thumbprint] = e;
            used.Add(e);
            var name = CertFacts.Name(c);
            if (CertFacts.IsSelfSigned(c))
            {
                e.Outcome = CertificateCheckOutcome.Root;
                e.Detail = "a root: needs no revocation data";
                return;
            }
            if (CertFacts.HasOcspNoCheck(c))
            {
                e.Outcome = CertificateCheckOutcome.NoCheckNeeded;
                e.Detail = "an OCSP responder that needs no check of its own";
                return;
            }
            if (issuer is null)
            {
                e.Outcome = CertificateCheckOutcome.NoIssuer;
                e.Detail = $"{name}'s issuer isn't in the file or on this PC, and couldn't be fetched";
                return;
            }
            if (useStored)
            {
                var (stored, at, responder, evidence) = Judge(c, issuer, when);
                if (stored is RevocationAnswer.Good or RevocationAnswer.Revoked or RevocationAnswer.RevokedLater)
                {
                    Record(e, stored, at, evidence!, responder, "already in the file");
                    await CoverResponder(e, issuer, when, used, cancel).ConfigureAwait(false);
                    return;
                }
            }

            var refused = 0;
            var tried = 0;
            string? failure = null;
            foreach (var url in CertFacts.OcspUrls(c))
            {
                if (client.Refuses(url, LtvAddressKind.Ocsp))
                {
                    refused++;
                    continue;
                }
                tried++;
                try
                {
                    var der = await client.PostAsync(url, LtvAddressKind.Ocsp, "application/ocsp-request", OcspResponse.Request(c, issuer), LtvClient.MaxOcspReply, cancel).ConfigureAwait(false);
                    if (OcspResponse.Parse(der, out var problem) is not { } reply)
                    {
                        failure ??= $"The answer from {LtvClient.Host(url)} can't be used: {problem}.";
                        continue;
                    }
                    if (reply.AnswerFor(c, issuer) is null || !reply.SignedFor(issuer, Pool.Certs, out _))
                    {
                        failure ??= $"The answer from {LtvClient.Host(url)} isn't signed by the certificate's issuer, or is about another certificate.";
                        continue;
                    }
                    Pool.AddOcsp(der);
                    var (answer, at, responder, evidence) = Judge(c, issuer, when);
                    if (answer == RevocationAnswer.Stale)
                    {
                        failure ??= $"The answer from {LtvClient.Host(url)} is too old to speak for the signing time.";
                        continue;
                    }
                    Record(e, answer, at, evidence ?? der, responder, $"OCSP, {LtvClient.Host(url)}");
                    await CoverResponder(e, issuer, when, used, cancel).ConfigureAwait(false);
                    return;
                }
                catch (LtvFetchException ex)
                {
                    failure ??= ex.Message;
                }
            }
            foreach (var url in CertFacts.CrlUrls(c))
            {
                if (client.Refuses(url, LtvAddressKind.Crl))
                {
                    refused++;
                    continue;
                }
                tried++;
                try
                {
                    var der = await client.GetAsync(url, LtvAddressKind.Crl, LtvClient.MaxCrlReply, cancel).ConfigureAwait(false);
                    if (CrlDocument.Parse(der) is not { } list || !list.SpeaksFor(c, issuer))
                    {
                        failure ??= $"The list from {LtvClient.Host(url)} can't be read, or isn't signed by the certificate's issuer.";
                        continue;
                    }
                    Pool.AddCrl(der);
                    var (answer, at, responder, evidence) = Judge(c, issuer, when);
                    if (answer == RevocationAnswer.Stale)
                    {
                        failure ??= $"The list from {LtvClient.Host(url)} is too old to speak for the signing time.";
                        continue;
                    }
                    Record(e, answer, at, evidence ?? der, responder, $"CRL, {LtvClient.Host(url)}");
                    return;
                }
                catch (LtvFetchException ex)
                {
                    failure ??= ex.Message;
                }
            }

            if (tried == 0)
            {
                e.Detail = refused > 0
                    ? $"{name} names only addresses on a local network or that can't be used, so none was contacted"
                    : $"{name} names no address to ask about it";
                return;
            }
            e.Detail = failure ?? $"{name} couldn't be asked about";
            FirstFailure ??= failure ?? e.Detail;
        }

        /// <summary>The pool's time budget is for the file's data: however long the servers took to answer, this question gets all of it.</summary>
        private (RevocationAnswer Answer, DateTimeOffset? RevokedAt, X509Certificate2? Responder, byte[]? Evidence) Judge(X509Certificate2 c, X509Certificate2 issuer, DateTimeOffset when)
        {
            Pool.RestartBudget();
            return Pool.Check(c, issuer, when);
        }

        private async Task CoverResponder(Entry e, X509Certificate2 issuer, DateTimeOffset when, List<Entry> used, CancellationToken cancel)
        {
            if (e.Responder is { } r && !_entries.ContainsKey(r.Thumbprint))
            {
                Pool.AddCert(r);
                await Cover(r, issuer, when, used, cancel).ConfigureAwait(false);
            }
        }

        private static void Record(Entry e, RevocationAnswer answer, DateTimeOffset? at, byte[] evidence, X509Certificate2? responder, string source)
        {
            e.Responder = responder;
            if (OcspResponse.Parse(evidence, out _) is not null) e.Ocsp = evidence;
            else e.Crl = evidence;
            (e.Outcome, e.Detail) = answer switch
            {
                RevocationAnswer.Good => (CertificateCheckOutcome.Good, $"not revoked ({source})"),
                RevocationAnswer.Revoked => (CertificateCheckOutcome.Revoked, $"REVOKED{(at is { } a ? $" on {a.UtcDateTime:yyyy-MM-dd}" : "")} ({source})"),
                RevocationAnswer.RevokedLater => (CertificateCheckOutcome.RevokedLater, $"revoked later, on {at?.UtcDateTime:yyyy-MM-dd}, after the signing time ({source})"),
                RevocationAnswer.Unknown => (CertificateCheckOutcome.Unknown, $"the authority doesn't know this certificate ({source})"),
                _ => (CertificateCheckOutcome.NoData, $"no usable answer ({source})"),
            };
        }
    }
}
