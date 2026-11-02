using System.IO.Compression;
using System.Net;
using System.Security.Cryptography;
using System.Security.Cryptography.X509Certificates;
using System.Text;
using System.Text.RegularExpressions;
using InkvoltPdf.Core;
using PdfSharp.Pdf;

namespace InkvoltPdf.Tests;

/// <summary>Long-term validation (roadmap 3.4): PAdES B-LT and B-LTA against a local authority, and what a hostile file can't make it do.</summary>
public class LtvTests
{
    private static byte[] SignBb(LtvTestPki pki, byte[]? pdf = null, SignatureFormat format = SignatureFormat.CAdES, CertificationLevel certify = CertificationLevel.None) =>
        Signing.Sign(pdf ?? TestPdf.Make(2), null, new SignRequest { Certificate = pki.Signer, Reason = "Approved", Format = format, Certify = certify });

    private static async Task<byte[]> SignLongTerm(LtvTestPki pki, LongTermLevel level, byte[]? pdf = null)
    {
        using var client = pki.Client();
        return await Signing.SignAsync(pdf ?? TestPdf.Make(2), null, new SignRequest
        {
            Certificate = pki.Signer,
            Reason = "Approved",
            Timestamp = client.TimestampSender(pki.TimestampUrl),
            LongTerm = level,
            LongTermClient = client,
        });
    }

    private static SignatureInfo First(byte[] pdf, LtvTestPki pki) => Signatures.Verify(pdf, null, pki.Anchors).First(s => s.SubFilter != "ETSI.RFC3161");

    /// <summary>How many streams a /DSS list holds.</summary>
    private static (int Certs, int Ocsps, int Crls, int Vri) Store(byte[] pdf)
    {
        using var doc = Core2Pdf.Open(pdf);
        var dss = PdfObj.Dict(doc.Internals.Catalog.Elements["/DSS"]);
        Assert.NotNull(dss);
        return (PdfObj.Array(dss.Elements["/Certs"])?.Elements.Count ?? 0, PdfObj.Array(dss.Elements["/OCSPs"])?.Elements.Count ?? 0,
            PdfObj.Array(dss.Elements["/CRLs"])?.Elements.Count ?? 0, PdfObj.Dict(dss.Elements["/VRI"])?.Elements.Count ?? 0);
    }

    // ---- Levels ----

    [Fact]
    public async Task Signing_for_the_long_term_stores_the_whole_chain_and_reaches_b_lt()
    {
        using var pki = new LtvTestPki();
        var pdf = await SignLongTerm(pki, LongTermLevel.Lt);
        var s = First(pdf, pki);
        Assert.Equal(SignatureStatus.Valid, s.Status);
        Assert.True(s.CertificateTrusted, s.CertificateStatus);
        Assert.NotNull(s.LongTerm);
        Assert.Equal(PadesLevel.BLT, s.LongTerm.Level);
        Assert.True(s.LongTerm.DataComplete);
        Assert.True(s.LongTerm.OnlyValidationDataAfter);
        Assert.Contains("LTV enabled", s.LongTerm.Summary);

        var (certs, ocsps, _, vri) = Store(pdf);
        Assert.True(certs >= 4, $"signer, intermediate, root, timestamp authority: {certs}");
        Assert.True(ocsps >= 3, $"signer, intermediate, timestamp authority: {ocsps}");
        Assert.Equal(1, vri);
        // The signer's intermediate wasn't on this PC or in the signature: it came from the address the certificate names.
        Assert.Contains(pki.Hits, h => h.StartsWith("/cert/", StringComparison.Ordinal));
    }

    [Fact]
    public async Task Signing_for_b_lta_adds_a_document_timestamp_and_its_authoritys_data()
    {
        using var pki = new LtvTestPki();
        var pdf = await SignLongTerm(pki, LongTermLevel.Lta);
        var all = Signatures.Verify(pdf, null, pki.Anchors);
        Assert.Equal(2, all.Count);
        var s = all.Single(x => x.SubFilter != "ETSI.RFC3161");
        var stamp = all.Single(x => x.SubFilter == "ETSI.RFC3161");
        Assert.Equal(SignatureStatus.Valid, s.Status);
        Assert.Equal(PadesLevel.BLTA, s.LongTerm!.Level);
        Assert.Equal(SignatureStatus.Valid, stamp.Status);
        Assert.True(stamp.HasTimestamp);
        Assert.True(stamp.CertificateTrusted, stamp.CertificateStatus);
        Assert.True(stamp.LongTerm!.DataComplete, stamp.LongTerm.Summary);
        Assert.Equal(2, Store(pdf).Vri);
    }

    [Fact]
    public void A_plain_signature_is_b_b_and_goes_nowhere()
    {
        using var pki = new LtvTestPki();
        var pdf = SignBb(pki);
        var s = First(pdf, pki);
        Assert.Equal(PadesLevel.BB, s.LongTerm!.Level);
        Assert.False(s.LongTerm.DataComplete);
        Assert.Empty(pki.Hits);
    }

    [Fact]
    public void An_adbe_pkcs7_signature_is_no_pades_level()
    {
        using var pki = new LtvTestPki();
        Assert.Equal(PadesLevel.None, First(SignBb(pki, format: SignatureFormat.Pkcs7), pki).LongTerm!.Level);
    }

    // ---- Add Verification Information ----

    [Fact]
    public async Task Adding_verification_information_is_an_update_that_leaves_the_signature_valid()
    {
        using var pki = new LtvTestPki();
        var signed = SignBb(pki);
        using var client = pki.Client();
        var result = await Ltv.AddVerificationAsync(signed, null, client);

        Assert.True(result.Changed);
        Assert.True(result.Pdf.AsSpan(0, signed.Length).SequenceEqual(signed), "the signed bytes stay as they were");
        var s = First(result.Pdf, pki);
        Assert.Equal(SignatureStatus.Valid, s.Status);
        Assert.True(s.LongTerm!.DataComplete);
        // No timestamp asked for: the data is in the file but nothing proves when it was signed.
        Assert.Equal(PadesLevel.BB, s.LongTerm.Level);
        Assert.Contains(result.Contacts, c => c.Kind == LtvAddressKind.Ocsp);
        Assert.All(result.Certificates, c => Assert.True(c.Covered, c.Outcome));
    }

    [Fact]
    public async Task Adding_verification_information_with_a_timestamp_reaches_b_lta()
    {
        using var pki = new LtvTestPki();
        var signed = SignBb(pki);
        using var client = pki.Client();
        var result = await Ltv.AddVerificationAsync(signed, null, client, client.TimestampSender(pki.TimestampUrl));
        Assert.True(result.Pdf.AsSpan(0, signed.Length).SequenceEqual(signed));
        Assert.Equal(PadesLevel.BLTA, First(result.Pdf, pki).LongTerm!.Level);
        Assert.Equal(SignatureStatus.Valid, First(result.Pdf, pki).Status);
        // One document timestamp gives a signature without one its time, the other goes over the data.
        Assert.Equal(2, Signatures.Verify(result.Pdf).Count(s => s.SubFilter == "ETSI.RFC3161"));
    }

    [Fact]
    public async Task A_b_t_signature_with_verification_information_reaches_b_lt()
    {
        using var pki = new LtvTestPki();
        using var client = pki.Client();
        var stamped = await Signing.SignAsync(TestPdf.Make(1), null, new SignRequest { Certificate = pki.Signer, Timestamp = client.TimestampSender(pki.TimestampUrl) });
        Assert.Equal(PadesLevel.BT, First(stamped, pki).LongTerm!.Level);
        var result = await Ltv.AddVerificationAsync(stamped, null, client);
        Assert.Equal(PadesLevel.BLT, First(result.Pdf, pki).LongTerm!.Level);
    }

    [Fact]
    public void The_suggested_timestamp_server_is_one_the_rules_accept() =>
        Assert.Null(LtvClient.WhyRefused(LtvPlan.SuggestedTimestampServer, LtvAddressKind.Timestamp));

    /// <summary>The real suggested server, opt-in (INKVOLTPDF_REAL_TSA set): it gets a hash of a test signature.</summary>
    [Fact]
    public async Task The_suggested_timestamp_server_answers_and_its_timestamp_verifies()
    {
        if (Environment.GetEnvironmentVariable("INKVOLTPDF_REAL_TSA") is not { Length: > 0 }) return;
        using var pki = new LtvTestPki();
        using var real = new LtvClient();
        var stamped = await Signing.SignAsync(TestPdf.Make(1), null, new SignRequest { Certificate = pki.Signer, Timestamp = real.TimestampSender(LtvPlan.SuggestedTimestampServer) });
        Assert.Equal(PadesLevel.BT, First(stamped, pki).LongTerm!.Level);
    }

    [Fact]
    public async Task Verification_information_works_on_every_signature_in_a_file()
    {
        using var pki = new LtvTestPki();
        using var other = pki.Issue("CN=Second Signer,O=Inkvolt Tests,C=PR", pki.Intermediate, ku: X509KeyUsageFlags.NonRepudiation);
        var once = SignBb(pki);
        var twice = Signing.Sign(once, null, new SignRequest { Certificate = other });
        using var client = pki.Client();
        var result = await Ltv.AddVerificationAsync(twice, null, client);
        var all = Signatures.Verify(result.Pdf, null, pki.Anchors);
        Assert.Equal(2, all.Count);
        Assert.All(all, s => Assert.True(s.LongTerm!.DataComplete, s.LongTerm.Summary));
        Assert.Equal(SignatureStatus.ModifiedAfterSigning, all.Single(s => s.SignerName!.Contains("Long-Term")).Status); // another signature followed it
        Assert.Equal(SignatureStatus.Valid, all.Single(s => s.SignerName == "Second Signer").Status);
        Assert.Equal(2, Store(result.Pdf).Vri);
    }

    [Fact]
    public async Task Verification_information_works_on_a_file_with_an_xref_stream()
    {
        using var pki = new LtvTestPki();
        var signed = Signing.Sign(IncrSignatureTests.SignedForm(xrefStream: true), null, new SignRequest { Certificate = pki.Signer });
        using var client = pki.Client();
        var result = await Ltv.AddVerificationAsync(signed, null, client);
        Assert.True(result.Pdf.AsSpan(0, signed.Length).SequenceEqual(signed));
        Assert.Equal(SignatureStatus.Valid, Signatures.Verify(result.Pdf, null, pki.Anchors).Single(s => s.SignerName!.Contains("Long-Term")).Status);
    }

    [Fact]
    public async Task A_no_changes_certification_takes_verification_information_and_a_timestamp()
    {
        using var pki = new LtvTestPki();
        var certified = SignBb(pki, certify: CertificationLevel.NoChanges);
        using var client = pki.Client();
        var result = await Ltv.AddVerificationAsync(certified, null, client, client.TimestampSender(pki.TimestampUrl));
        var s = First(result.Pdf, pki);
        Assert.Equal(1, s.CertificationLevel);
        Assert.Equal(SignatureStatus.Valid, s.Status);
        Assert.Equal(PadesLevel.BLTA, s.LongTerm!.Level);
        // And the certification still bites after them.
        var noted = Annotations.AddNote(result.Pdf, null, 0, 100, 100, "Hello", "Eve");
        Assert.Equal(SignatureStatus.DisallowedChanges, First(noted, pki).Status);
    }

    [Fact]
    public async Task A_second_run_with_nothing_new_changes_nothing_and_asks_nobody()
    {
        using var pki = new LtvTestPki();
        using var client = pki.Client();
        var done = (await Ltv.AddVerificationAsync(SignBb(pki), null, client)).Pdf;
        var before = pki.Hits.Count;
        using var again = pki.Client();
        var second = await Ltv.AddVerificationAsync(done, null, again);
        Assert.False(second.Changed);
        Assert.Equal(done, second.Pdf);
        Assert.Equal(before, pki.Hits.Count);
        Assert.Empty(second.Contacts);
        Assert.True(Ltv.Plan(done).Complete);
    }

    [Fact]
    public async Task A_timestamp_can_be_renewed_over_earlier_ones()
    {
        using var pki = new LtvTestPki();
        var lta = await SignLongTerm(pki, LongTermLevel.Lta);
        using var client = pki.Client();
        var renewed = await Ltv.AddVerificationAsync(lta, null, client, client.TimestampSender(pki.TimestampUrl));
        var all = Signatures.Verify(renewed.Pdf, null, pki.Anchors);
        Assert.Equal(2, all.Count(s => s.SubFilter == "ETSI.RFC3161"));
        Assert.Equal(PadesLevel.BLTA, all.Single(s => s.SubFilter != "ETSI.RFC3161").LongTerm!.Level);
        Assert.All(all, s => Assert.Equal(SignatureStatus.Valid, s.Status));
    }

    [Fact]
    public async Task A_delegated_responder_counts_when_its_issuer_delegated_it()
    {
        using var pki = new LtvTestPki { DelegateOcsp = true };
        var pdf = await SignLongTerm(pki, LongTermLevel.Lt);
        var s = First(pdf, pki);
        Assert.Equal(PadesLevel.BLT, s.LongTerm!.Level);
        Assert.Contains(s.LongTerm.Chain, c => c.Name == "Test OCSP Responder" && c.Outcome == CertificateCheckOutcome.NoCheckNeeded);
    }

    [Fact]
    public async Task A_self_signed_id_stores_itself_and_asks_nobody()
    {
        using var pki = new LtvTestPki();
        var pfx = DigitalIds.CreatePersonalPfx("Grace Hopper", null, null, "secret");
        using var id = DigitalIds.LoadPfx(pfx, "secret");
        var signed = Signing.Sign(TestPdf.Make(1), null, new SignRequest { Certificate = id });
        using var client = pki.Client();
        var result = await Ltv.AddVerificationAsync(signed, null, client);
        Assert.Empty(result.Contacts);
        Assert.Empty(pki.Hits);
        Assert.Equal(SignatureStatus.Valid, Assert.Single(Signatures.Verify(result.Pdf)).Status);
        Assert.True(Store(result.Pdf).Certs >= 1);
    }

    // ---- Revocation ----

    [Fact]
    public async Task A_certificate_revoked_before_signing_loses_its_trust_from_the_file_alone()
    {
        using var pki = new LtvTestPki();
        pki.Revoke(pki.Signer, DateTimeOffset.UtcNow.AddDays(-1));
        var signed = SignBb(pki);
        Assert.DoesNotContain("Revoked", First(signed, pki).CertificateStatus); // nothing in the file says so yet
        using var client = pki.Client();
        var result = await Ltv.AddVerificationAsync(signed, null, client);
        var s = First(result.Pdf, pki);
        Assert.False(s.CertificateTrusted);
        Assert.Contains("Revoked", s.CertificateStatus);
        Assert.Contains(result.Certificates, c => c.Outcome.Contains("REVOKED"));
        Assert.Contains(s.LongTerm!.Chain, c => c.Outcome == CertificateCheckOutcome.Revoked);
    }

    [Fact]
    public async Task A_revoked_id_can_t_sign_for_the_long_term()
    {
        using var pki = new LtvTestPki();
        pki.Revoke(pki.Signer, DateTimeOffset.UtcNow.AddDays(-1));
        var ex = await Assert.ThrowsAsync<SigningException>(() => SignLongTerm(pki, LongTermLevel.Lt));
        Assert.Contains("revoked", ex.Message);
    }

    [Fact]
    public async Task A_revocation_after_a_trusted_timestamp_doesn_t_touch_the_signature()
    {
        using var pki = new LtvTestPki();
        using var client = pki.Client();
        var stamped = await Signing.SignAsync(TestPdf.Make(1), null, new SignRequest { Certificate = pki.Signer, Timestamp = client.TimestampSender(pki.TimestampUrl) });
        pki.Revoke(pki.Signer, DateTimeOffset.UtcNow.AddHours(1));
        var result = await Ltv.AddVerificationAsync(stamped, null, client);
        var s = First(result.Pdf, pki);
        Assert.True(s.CertificateTrusted, s.CertificateStatus);
        Assert.Contains(s.LongTerm!.Chain, c => c.Outcome == CertificateCheckOutcome.RevokedLater);
        Assert.Contains("revoked later", s.LongTerm.Summary);
    }

    [Fact]
    public async Task Crl_answers_when_the_responder_doesn_t()
    {
        using var pki = new LtvTestPki();
        pki.Overrides["/ocsp"] = _ => Task.FromResult(LtvTestPki.Http(500, []));
        var pdf = await SignLongTerm(pki, LongTermLevel.Lt);
        var s = First(pdf, pki);
        Assert.Equal(PadesLevel.BLT, s.LongTerm!.Level);
        Assert.True(Store(pdf).Crls >= 2);
        Assert.Equal(0, Store(pdf).Ocsps);
    }

    [Fact]
    public async Task A_listed_certificate_on_a_crl_counts_as_revoked()
    {
        using var pki = new LtvTestPki();
        pki.Overrides["/ocsp"] = _ => Task.FromResult(LtvTestPki.Http(503, []));
        pki.Revoke(pki.Signer, DateTimeOffset.UtcNow.AddDays(-2));
        var signed = SignBb(pki);
        using var client = pki.Client();
        var s = First((await Ltv.AddVerificationAsync(signed, null, client)).Pdf, pki);
        Assert.False(s.CertificateTrusted);
        Assert.Contains("Revoked", s.CertificateStatus);
    }

    [Fact]
    public async Task Checking_online_changes_nothing_and_finds_a_revocation()
    {
        using var pki = new LtvTestPki();
        var signed = SignBb(pki);
        pki.Revoke(pki.Signer, DateTimeOffset.UtcNow.AddDays(-1));
        using var client = pki.Client();
        var online = await Ltv.CheckOnlineAsync(signed, null, client);
        Assert.Null(online.Problem);
        Assert.Contains(online.Certificates, c => c.Outcome.Contains("REVOKED"));
        var checkedNow = Signatures.Verify(signed, null, online.Snapshot).First();
        Assert.False(checkedNow.CertificateTrusted);
        Assert.Contains("Revoked", checkedNow.CertificateStatus);
        // Once more without it: the check was for that moment only, and the file holds nothing.
        Assert.DoesNotContain("Revoked", Signatures.Verify(signed).First().CertificateStatus);
    }

    // ---- Offline, and servers that misbehave ----

    [Fact]
    public async Task Offline_adding_fails_clearly_and_leaves_the_input_alone()
    {
        using var pki = new LtvTestPki();
        var signed = SignBb(pki);
        var copy = signed.ToArray();
        pki.Dispose(); // the "internet" is gone
        using var client = pki.Client(TimeSpan.FromSeconds(3));
        var ex = await Assert.ThrowsAsync<SigningException>(() => Ltv.AddVerificationAsync(signed, null, client));
        Assert.Contains("Nothing was changed", ex.Message);
        Assert.Contains("can't be reached", ex.Message);
        Assert.Equal(copy, signed);
    }

    [Fact]
    public async Task Offline_signing_for_the_long_term_gives_no_file()
    {
        using var pki = new LtvTestPki();
        pki.Overrides["/ocsp"] = _ => Task.FromResult(LtvTestPki.Http(503, []));
        foreach (var path in new[] { pki.Intermediate, pki.Root }) pki.Overrides[$"/crl/{path.Thumbprint}.crl"] = _ => Task.FromResult(LtvTestPki.Http(503, []));
        var ex = await Assert.ThrowsAsync<SigningException>(() => SignLongTerm(pki, LongTermLevel.Lta));
        Assert.Contains("answered with an error", ex.Message);
        Assert.Contains("Nothing was changed", ex.Message);
    }

    [Fact]
    public async Task A_timestamp_server_that_fails_leaves_no_half_written_file()
    {
        using var pki = new LtvTestPki();
        var signed = SignBb(pki);
        using var client = pki.Client();
        var ex = await Assert.ThrowsAsync<SigningException>(() => Ltv.AddVerificationAsync(signed, null, client, (_, _) => throw new LtvFetchException("no.example.com can't be reached.")));
        Assert.Contains("Nothing was changed", ex.Message);
    }

    [Theory]
    [InlineData("garbage")]
    [InlineData("forged")]
    [InlineData("other")]
    public async Task A_responder_s_bad_answer_is_not_stored(string kind)
    {
        using var pki = new LtvTestPki();
        using var forger = RSA.Create(2048);
        pki.Overrides["/ocsp"] = body => Task.FromResult(LtvTestPki.Http(200, kind switch
        {
            "garbage" => Encoding.ASCII.GetBytes("<html>Sign in to the hotel Wi-Fi</html>"),
            "forged" => pki.OcspReply(body, forged()),
            _ => pki.OcspReply(LtvTestPki.OcspRequest(pki.Intermediate, pki.Root)),
        }));
        RSA forged() => forger;
        // Nothing else answers either, so the run ends with the responder's problem.
        foreach (var path in new[] { pki.Intermediate, pki.Root }) pki.Overrides[$"/crl/{path.Thumbprint}.crl"] = _ => Task.FromResult(LtvTestPki.Http(404, []));
        var signed = SignBb(pki);
        using var client = pki.Client();
        var ex = await Assert.ThrowsAsync<SigningException>(() => Ltv.AddVerificationAsync(signed, null, client));
        Assert.Contains("Nothing was changed", ex.Message);
    }

    [Fact]
    public async Task An_answer_too_old_for_the_signing_time_isn_t_stored()
    {
        using var pki = new LtvTestPki();
        pki.Overrides["/ocsp"] = body => Task.FromResult(LtvTestPki.Http(200, pki.OcspReply(body, thisUpdate: DateTimeOffset.UtcNow.AddDays(-30))));
        foreach (var path in new[] { pki.Intermediate, pki.Root }) pki.Overrides[$"/crl/{path.Thumbprint}.crl"] = _ => Task.FromResult(LtvTestPki.Http(404, []));
        using var client = pki.Client();
        var stamped = await Signing.SignAsync(TestPdf.Make(1), null, new SignRequest { Certificate = pki.Signer, Timestamp = client.TimestampSender(pki.TimestampUrl) });
        var ex = await Assert.ThrowsAsync<SigningException>(() => Ltv.AddVerificationAsync(stamped, null, client));
        Assert.Contains("too old", ex.Message);
        Assert.Contains("Nothing was changed", ex.Message);
    }

    [Fact]
    public async Task An_oversized_reply_is_cut_off()
    {
        using var pki = new LtvTestPki();
        pki.Overrides["/big"] = _ => Task.FromResult(LtvTestPki.Http(200, new byte[LtvClient.MaxOcspReply + 1]));
        pki.Overrides["/chunked"] = _ =>
        {
            var chunk = new byte[200_000];
            var head = Encoding.ASCII.GetBytes("HTTP/1.1 200 X\r\nTransfer-Encoding: chunked\r\nConnection: close\r\n\r\n");
            var one = (byte[])[.. Encoding.ASCII.GetBytes($"{chunk.Length:X}\r\n"), .. chunk, .. "\r\n"u8];
            return Task.FromResult<byte[]>([.. head, .. one, .. one, .. "0\r\n\r\n"u8]);
        };
        using var client = pki.Client();
        var a = await Assert.ThrowsAsync<LtvFetchException>(() => client.GetAsync($"{pki.BaseUrl}/big", LtvAddressKind.Ocsp, LtvClient.MaxOcspReply));
        Assert.Contains("more than", a.Message);
        var b = await Assert.ThrowsAsync<LtvFetchException>(() => client.GetAsync($"{pki.BaseUrl}/chunked", LtvAddressKind.Ocsp, LtvClient.MaxOcspReply));
        Assert.Contains("more than", b.Message);
    }

    [Fact]
    public async Task A_server_that_stalls_runs_out_of_time()
    {
        using var pki = new LtvTestPki();
        pki.Overrides["/slow"] = async _ =>
        {
            await Task.Delay(TimeSpan.FromSeconds(20));
            return LtvTestPki.Http(200, []);
        };
        using var client = pki.Client(TimeSpan.FromMilliseconds(400));
        var clock = System.Diagnostics.Stopwatch.StartNew();
        var ex = await Assert.ThrowsAsync<LtvFetchException>(() => client.GetAsync($"{pki.BaseUrl}/slow", LtvAddressKind.Crl, 1000));
        Assert.Contains("didn't answer in time", ex.Message);
        Assert.True(clock.Elapsed < TimeSpan.FromSeconds(5), clock.Elapsed.ToString());
    }

    [Fact]
    public async Task A_timestamp_server_must_be_https()
    {
        Assert.Contains("https", LtvClient.WhyRefused("http://timestamp.example.com/", LtvAddressKind.Timestamp));
        Assert.Null(LtvClient.WhyRefused("https://timestamp.example.com/", LtvAddressKind.Timestamp));
        Assert.Null(LtvClient.WhyRefused("http://ocsp.example.com/", LtvAddressKind.Ocsp)); // as the certificate names it
        using var client = new LtvClient();
        var ex = await Assert.ThrowsAsync<LtvFetchException>(() => client.TimestampSender("http://timestamp.example.com/")(new byte[1], default));
        Assert.Contains("https", ex.Message);
    }

    // ---- A file must not be able to make the app probe the local network ----

    [Theory]
    [InlineData("http://127.0.0.1/")]
    [InlineData("http://127.1/")]
    [InlineData("http://2130706433/")]
    [InlineData("http://0x7f.0.0.1/")]
    [InlineData("http://localhost/")]
    [InlineData("http://x.localhost/")]
    [InlineData("http://localhost./")]
    [InlineData("http://127。0。0。1/")]
    [InlineData("http://ｌｏｃａｌｈｏｓｔ/")]
    [InlineData("HTTP://LOCALHOST/")]
    [InlineData("http://[::1]/")]
    [InlineData("http://[::ffff:127.0.0.1]/")]
    [InlineData("http://0.0.0.0/")]
    [InlineData("http://10.0.0.1/")]
    [InlineData("http://172.16.0.1/")]
    [InlineData("http://192.168.1.1/admin")]
    [InlineData("http://169.254.169.254/latest/meta-data/")]
    [InlineData("http://100.64.0.1/")]
    [InlineData("http://[fe80::1]/")]
    [InlineData("http://[fc00::1]/")]
    [InlineData("http://[fd12:3456::1]/")]
    [InlineData("http://printer/")]
    [InlineData("http://nas.local/")]
    [InlineData("http://router.lan/")]
    [InlineData("http://service.internal/")]
    [InlineData("http://224.0.0.1/")]
    [InlineData("file:///C:/Windows/win.ini")]
    [InlineData("ldap://directory.example.com/")]
    [InlineData("ftp://example.com/x.crl")]
    [InlineData("https://user:pw@example.com/")]
    public void Addresses_on_this_pc_or_a_local_network_are_refused(string url) =>
        Assert.NotNull(LtvClient.WhyRefused(url, LtvAddressKind.Ocsp));

    [Theory]
    [InlineData("http://ocsp.example.com/")]
    [InlineData("https://crl.example.com/ca.crl")]
    [InlineData("http://93.184.216.34/")]
    public void Public_addresses_a_certificate_names_are_fine(string url) =>
        Assert.Null(LtvClient.WhyRefused(url, LtvAddressKind.Crl));

    [Theory]
    [InlineData("127.0.0.1", false)]
    [InlineData("10.1.2.3", false)]
    [InlineData("192.168.0.10", false)]
    [InlineData("169.254.169.254", false)]
    [InlineData("::1", false)]
    [InlineData("fe80::1", false)]
    [InlineData("fc00::1", false)]
    [InlineData("::ffff:192.168.0.1", false)]
    [InlineData("64:ff9b::a00:1", false)]    // NAT64 of 10.0.0.1
    [InlineData("2002:a00:1::", false)]      // 6to4 of 10.0.0.1
    [InlineData("2001::1", false)]           // Teredo
    [InlineData("ff02::1", false)]
    [InlineData("93.184.216.34", true)]
    [InlineData("2606:2800:220:1::1", true)]
    public void Which_addresses_count_as_public(string address, bool expected) =>
        Assert.Equal(expected, LtvClient.IsPublic(IPAddress.Parse(address)));

    [Fact]
    public async Task An_ordinary_client_won_t_reach_a_listener_on_this_pc()
    {
        using var pki = new LtvTestPki();
        using var client = new LtvClient();
        var ex = await Assert.ThrowsAsync<LtvFetchException>(() => client.GetAsync($"{pki.BaseUrl}/crl/x.crl", LtvAddressKind.Crl, 1000));
        Assert.Contains("wasn't contacted", ex.Message);
        Assert.Empty(pki.Hits);
    }

    [Fact]
    public async Task A_public_looking_name_that_resolves_to_this_pc_isn_t_contacted()
    {
        // DNS rebinding: the name looks public and resolves to loopback or the router when asked.
        using var pki = new LtvTestPki();
        var port = new Uri(pki.BaseUrl).Port;
        foreach (var answer in new[] { IPAddress.Loopback, IPAddress.Parse("192.168.1.1"), IPAddress.Parse("169.254.169.254") })
        {
            using var client = new LtvClient(false, TimeSpan.FromSeconds(3), (_, _) => Task.FromResult<IPAddress[]>([IPAddress.Parse("93.184.216.34"), answer]));
            var ex = await Assert.ThrowsAsync<LtvFetchException>(() => client.GetAsync($"http://ocsp.example.com:{port}/ocsp", LtvAddressKind.Ocsp, 1000));
            Assert.Contains("wasn't contacted", ex.Message);
        }
        Assert.Empty(pki.Hits);
    }

    [Theory]
    [InlineData("http://192.168.1.1/admin")]
    [InlineData("http://169.254.169.254/latest/meta-data/")]
    [InlineData("http://10.0.0.1/")]
    [InlineData("http://[fe80::1]/")]
    [InlineData("file:///C:/Windows/win.ini")]
    public async Task A_redirect_to_a_local_address_isn_t_followed(string target)
    {
        using var pki = new LtvTestPki();
        pki.Overrides["/go"] = _ => Task.FromResult(LtvTestPki.Http(302, [], $"Location: {target}"));
        // Loopback is let through here only so the first hop gets anywhere in a test; everything else stays refused.
        using var local = pki.Client();
        var ex = await Assert.ThrowsAsync<LtvFetchException>(() => local.GetAsync($"{pki.BaseUrl}/go", LtvAddressKind.Crl, 1000));
        Assert.Contains("wasn't contacted", ex.Message);
    }

    [Fact]
    public async Task Redirects_end_somewhere()
    {
        using var pki = new LtvTestPki();
        pki.Overrides["/loop"] = _ => Task.FromResult(LtvTestPki.Http(302, [], $"Location: {pki.BaseUrl}/loop"));
        using var client = pki.Client();
        var ex = await Assert.ThrowsAsync<LtvFetchException>(() => client.GetAsync($"{pki.BaseUrl}/loop", LtvAddressKind.Crl, 1000));
        Assert.Contains("too many", ex.Message);
        Assert.InRange(pki.Hits.Count, 1, 5);
    }

    [Fact]
    public async Task Opening_and_verifying_a_file_contacts_nothing_its_certificates_name()
    {
        // The signer's issuer isn't in the file or on this PC, and its certificate names this listener for everything: a
        // chain build left alone would fetch the issuer from it, and a revocation check would ask it too.
        using var pki = new LtvTestPki();
        var signed = SignBb(pki);
        var viaDss = (await Ltv.AddVerificationAsync(SignBb(pki), null, pki.Client())).Pdf;
        var hitsBefore = pki.Hits.Count;

        Assert.False(Assert.Single(Signatures.Verify(signed)).CertificateTrusted);
        Signatures.BrokenByEdits(Signatures.Verify(signed), signed);
        Signatures.Verify(viaDss);
        Ltv.Plan(signed);
        Assert.Equal(hitsBefore, pki.Hits.Count);
    }

    [Fact]
    public void Signing_goes_nowhere_either()
    {
        using var pki = new LtvTestPki();
        var signed = SignBb(pki);
        Assert.Empty(pki.Hits);
        Assert.Equal(SignatureStatus.Valid, Assert.Single(Signatures.Verify(signed)).Status);
    }

    [Fact]
    public async Task Certificates_that_name_local_addresses_are_listed_as_refused_and_reported()
    {
        using var pki = new LtvTestPki();
        using var hostile = pki.Issue("CN=Hostile,O=Inkvolt Tests,C=PR", pki.Intermediate, ku: X509KeyUsageFlags.NonRepudiation,
            ocsp: ["http://192.168.1.1/probe"], crl: ["http://169.254.169.254/latest/meta-data/"], issuers: [$"{pki.BaseUrl}/cert/{pki.Intermediate.Thumbprint}.cer"]);
        var signed = Signing.Sign(TestPdf.Make(1), null, new SignRequest { Certificate = hostile });

        var plan = Ltv.Plan(signed);
        Assert.Contains(plan.Addresses, a => a.Url.Contains("192.168.1.1") && a.RefusedBecause is not null);
        Assert.Contains(plan.Addresses, a => a.Url.Contains("169.254") && a.RefusedBecause is not null);

        using var client = pki.Client(TimeSpan.FromSeconds(3));
        var result = await Ltv.AddVerificationAsync(signed, null, client);
        Assert.DoesNotContain(result.Contacts, c => c.Url.Contains("192.168") || c.Url.Contains("169.254"));
        Assert.Contains(result.Certificates, c => !c.Covered && c.Name == "Hostile" && c.Outcome.Contains("local network"));
        Assert.Equal(SignatureStatus.Valid, First(result.Pdf, pki).Status);
        Assert.False(First(result.Pdf, pki).LongTerm!.DataComplete);

        // Signing for the long term with such an ID promises something it can't keep.
        var ex = await Assert.ThrowsAsync<SigningException>(async () => await Signing.SignAsync(TestPdf.Make(1), null, new SignRequest
        {
            Certificate = hostile,
            Timestamp = client.TimestampSender(pki.TimestampUrl),
            LongTerm = LongTermLevel.Lt,
            LongTermClient = client,
        }));
        Assert.Contains("can't be complete", ex.Message);
    }

    [Fact]
    public void The_plan_says_where_it_would_go_without_going()
    {
        using var pki = new LtvTestPki();
        var signed = SignBb(pki);
        var plan = Ltv.Plan(signed);
        Assert.Empty(pki.Hits);
        Assert.False(plan.Complete);
        Assert.Contains(plan.Addresses, a => a.Kind == LtvAddressKind.Ocsp && a.ForWhom == "Test Long-Term Signer");
        Assert.Contains(plan.Addresses, a => a.Kind == LtvAddressKind.Issuer);
        Assert.All(plan.Addresses, a => Assert.NotNull(a.RefusedBecause)); // the listener's on loopback, which no real client reaches
        foreach (var kind in Enum.GetValues<LtvAddressKind>()) Assert.NotEmpty(LtvPlan.WhatIsSent(kind));
    }

    // ---- Hostile stores ----

    /// <summary>Appends an update that points the catalog's /DSS at <paramref name="dss"/>, with any extra objects.</summary>
    private static byte[] WithDss(byte[] pdf, string dss, IReadOnlyDictionary<int, byte[]>? objects = null)
    {
        var text = Encoding.Latin1.GetString(pdf);
        var root = int.Parse(Regex.Matches(text, @"/Root (\d+) \d+ R").Last().Groups[1].Value);
        var start = text.LastIndexOf($"\n{root} 0 obj", StringComparison.Ordinal) + $"\n{root} 0 obj".Length;
        var body = text[start..text.IndexOf("endobj", start, StringComparison.Ordinal)].Trim();
        body = body[..body.LastIndexOf(">>", StringComparison.Ordinal)] + $" /DSS {dss} >>";
        var size = Regex.Matches(text, @"/Size (\d+)").Max(m => int.Parse(m.Groups[1].Value));
        var prev = Regex.Matches(text, @"startxref\s+(\d+)").Last().Groups[1].Value;
        var all = new SortedDictionary<int, byte[]>(objects?.ToDictionary() ?? []) { [root] = Encoding.Latin1.GetBytes(body) };
        using var ms = new MemoryStream();
        ms.Write(pdf);
        ms.WriteByte((byte)'\n');
        var offsets = new SortedDictionary<int, long>();
        foreach (var (n, value) in all)
        {
            offsets[n] = ms.Position;
            ms.Write(Encoding.Latin1.GetBytes($"{n} 0 obj\n"));
            ms.Write(value);
            ms.Write("\nendobj\n"u8);
        }
        var xref = ms.Position;
        var sb = new StringBuilder("xref\n");
        foreach (var (n, at) in offsets) sb.Append($"{n} 1\n{at:D10} 00000 n \n");
        sb.Append($"trailer\n<< /Size {Math.Max(size, offsets.Keys.Max() + 1)} /Root {root} 0 R /Prev {prev} >>\nstartxref\n{xref}\n%%EOF\n");
        ms.Write(Encoding.Latin1.GetBytes(sb.ToString()));
        return ms.ToArray();
    }

    private static byte[] StreamObject(byte[] data, string extra = "")
    {
        using var ms = new MemoryStream();
        ms.Write(Encoding.ASCII.GetBytes($"<< /Length {data.Length}{extra} >>\nstream\n"));
        ms.Write(data);
        ms.Write("\nendstream"u8);
        return ms.ToArray();
    }

    public static TheoryData<string> Shapes => new()
    {
        "/Name",
        "42",
        "null",
        "(a string)",
        "[1 2 3]",
        "<< /Certs /Nope /OCSPs 7 /CRLs (x) /VRI [1] >>",
        "<< /Certs [999 0 R] /OCSPs [null 1 (x) [] <<>>] /CRLs [<< /Length 5 >>] >>",
        "<< /VRI << /ABC /Nope /DEF << /Cert 5 /OCSP (x) /CRL [999 0 R] >> >> >>",
    };

    [Theory]
    [MemberData(nameof(Shapes))]
    public void A_store_of_the_wrong_shape_is_no_store(string dss)
    {
        using var pki = new LtvTestPki();
        var s = First(WithDss(SignBb(pki), dss), pki);
        Assert.Equal(SignatureStatus.Valid, s.Status);
        Assert.False(s.LongTerm!.DataComplete);
    }

    [Fact]
    public void A_store_that_refers_to_itself_is_no_store()
    {
        using var pki = new LtvTestPki();
        const int n = 900;
        var pdf = WithDss(SignBb(pki), $"{n} 0 R", new Dictionary<int, byte[]>
        {
            [n] = Encoding.ASCII.GetBytes($"<< /Certs {n + 1} 0 R /OCSPs [{n} 0 R] /CRLs [{n + 1} 0 R] /VRI {n} 0 R >>"),
            [n + 1] = Encoding.ASCII.GetBytes($"[{n + 1} 0 R {n} 0 R]"),
        });
        Assert.Equal(SignatureStatus.Valid, First(pdf, pki).Status);
    }

    [Fact]
    public void Garbage_and_oversized_data_in_a_store_are_skipped_quickly()
    {
        using var pki = new LtvTestPki();
        var objects = new Dictionary<int, byte[]>();
        var lists = new StringBuilder();
        var n = 1000;
        // Far more streams than a store is read for, and streams too large to read.
        for (var i = 0; i < 1500; i++, n++)
        {
            objects[n] = StreamObject(RandomNumberGenerator.GetBytes(32));
            lists.Append($"{n} 0 R ");
        }
        objects[n] = StreamObject(new byte[RevocationPool.MaxCertBytes + 1]);
        lists.Append($"{n} 0 R ");
        var pdf = WithDss(SignBb(pki), $"<< /Certs [{lists}] /OCSPs [{lists}] /CRLs [{lists}] >>", objects);
        var clock = System.Diagnostics.Stopwatch.StartNew();
        var s = First(pdf, pki);
        Assert.Equal(SignatureStatus.Valid, s.Status);
        Assert.True(clock.Elapsed < TimeSpan.FromSeconds(30), clock.Elapsed.ToString());
    }

    [Fact]
    public void A_compressed_stream_that_explodes_isn_t_inflated()
    {
        using var pki = new LtvTestPki();
        using var packed = new MemoryStream();
        using (var z = new ZLibStream(packed, CompressionLevel.SmallestSize, leaveOpen: true))
            for (var i = 0; i < 400; i++)
                z.Write(new byte[1024 * 1024]); // 400 MB of zeros, about 400 KB packed
        var pdf = WithDss(SignBb(pki), "<< /CRLs [950 0 R] /OCSPs [950 0 R] /Certs [950 0 R] >>",
            new Dictionary<int, byte[]> { [950] = StreamObject(packed.ToArray(), " /Filter /FlateDecode") });
        var before = GC.GetAllocatedBytesForCurrentThread();
        var s = First(pdf, pki);
        Assert.Equal(SignatureStatus.Valid, s.Status);
        Assert.True(GC.GetAllocatedBytesForCurrentThread() - before < 300_000_000, "stopped long before the end of it");
    }

    [Fact]
    public async Task A_forged_answer_in_a_store_counts_for_nothing()
    {
        using var pki = new LtvTestPki();
        using var forger = RSA.Create(2048);
        var signed = SignBb(pki);
        using var client = pki.Client();
        var real = (await Ltv.AddVerificationAsync(signed, null, client)).Pdf;
        Assert.True(First(real, pki).LongTerm!.DataComplete);

        // "Good", in the responder's format, signed by nobody it should be. And a forged "revoked" doesn't take trust away.
        var forgedGood = pki.OcspReply(LtvTestPki.OcspRequest(pki.Signer, pki.Intermediate), forger);
        pki.Revoke(pki.Signer, DateTimeOffset.UtcNow.AddDays(-1));
        var forgedRevoked = pki.OcspReply(LtvTestPki.OcspRequest(pki.Signer, pki.Intermediate), forger);
        var pdf = WithDss(signed, "<< /OCSPs [950 0 R 951 0 R] >>", new Dictionary<int, byte[]>
        {
            [950] = StreamObject(forgedGood),
            [951] = StreamObject(forgedRevoked),
        });
        var s = First(pdf, pki);
        Assert.DoesNotContain("Revoked", s.CertificateStatus);
        Assert.False(s.LongTerm!.DataComplete);
        Assert.Contains(s.LongTerm.Chain, c => c.Name == "Test Long-Term Signer" && c.Outcome is CertificateCheckOutcome.NoData or CertificateCheckOutcome.NoIssuer);
    }

    [Fact]
    public async Task A_store_cant_hide_a_change_to_the_document()
    {
        using var pki = new LtvTestPki();
        using var client = pki.Client();
        var pdf = (await Ltv.AddVerificationAsync(SignBb(pki), null, client)).Pdf;
        Assert.Equal(SignatureStatus.Valid, First(pdf, pki).Status);
        // A comment added on top of the data: no longer only validation data.
        var noted = Annotations.AddNote(pdf, null, 0, 100, 100, "Later", "Eve");
        var s = First(noted, pki);
        Assert.Equal(SignatureStatus.ModifiedAfterSigning, s.Status);
        Assert.False(s.LongTerm!.OnlyValidationDataAfter);
    }

    [Fact]
    public async Task Encrypted_files_are_refused_with_a_reason()
    {
        using var pki = new LtvTestPki();
        using var client = pki.Client();
        var ex = await Assert.ThrowsAsync<SigningException>(() => Ltv.AddVerificationAsync(TestPdf.Encrypted(1, "pw"), "pw", client));
        Assert.Contains("Encrypted", ex.Message);
    }

    [Fact]
    public async Task A_file_without_signatures_has_nothing_to_add()
    {
        using var pki = new LtvTestPki();
        using var client = pki.Client();
        var ex = await Assert.ThrowsAsync<SigningException>(() => Ltv.AddVerificationAsync(TestPdf.Make(1), null, client));
        Assert.Contains("isn't signed", ex.Message);
        Assert.Empty(pki.Hits);
    }

    // ---- What only looks like validation data ----

    private static double PixelsChanged(byte[] a, byte[] b)
    {
        using var ea = PdfEngine.Open(a, MuPDFCore.InputFileTypes.PDF, null);
        using var eb = PdfEngine.Open(b, MuPDFCore.InputFileTypes.PDF, null);
        var (pa, pb) = (ea.Render(0, 1).Pixels, eb.Render(0, 1).Pixels);
        Assert.Equal(pa.Length, pb.Length);
        return (double)Enumerable.Range(0, pa.Length).Count(i => pa[i] != pb[i]) / pa.Length;
    }

    private static PdfDictionary Overlay(PdfDocument doc, string subtype, int x1, int y1, int x2, int y2, int flags)
    {
        var annot = new PdfDictionary(doc);
        annot.Elements["/Type"] = new PdfName("/Annot");
        annot.Elements["/Subtype"] = new PdfName(subtype);
        annot.Elements["/F"] = new PdfInteger(flags);
        annot.Elements["/Rect"] = new PdfArray(doc, new PdfInteger(x1), new PdfInteger(y1), new PdfInteger(x2), new PdfInteger(y2));
        var look = PdfObj.FormXObject(doc, "0 0 0 rg 0 0 300 300 re f"u8.ToArray(), 0, 0, 300, 300, null);
        annot.Elements["/AP"] = new PdfDictionary(doc) { Elements = { ["/N"] = look.Reference! } };
        return annot;
    }

    /// <summary>An update adding a signature field that says it is a document timestamp and has nothing behind that but the name.</summary>
    private static byte[] WithFakeTimestamp(byte[] signed, int x1, int y1, int x2, int y2, int flags)
    {
        using var doc = Signing.OpenForAppend(signed, null)!;
        var page = doc.Pages[0];
        var widget = Overlay(doc, "/Widget", x1, y1, x2, y2, flags);
        widget.Elements["/FT"] = new PdfName("/Sig");
        widget.Elements["/T"] = PdfObj.MakeString("Timestamp9");
        widget.Elements["/P"] = page.Reference!;
        var sig = new PdfDictionary(doc);
        sig.Elements["/SubFilter"] = new PdfName("/ETSI.RFC3161");
        doc.Internals.AddObject(sig);
        widget.Elements["/V"] = sig.Reference!;
        doc.Internals.AddObject(widget);
        PdfObj.Annots(doc, page).Elements.Add(widget.Reference!);
        PdfObj.Array(PdfObj.Dict(doc.Internals.Catalog.Elements["/AcroForm"])!.Elements["/Fields"])!.Elements.Add(widget.Reference!);
        return Incremental.TrySave(doc, null)!;
    }

    [Theory]
    [InlineData(CertificationLevel.None, SignatureStatus.ModifiedAfterSigning)]
    [InlineData(CertificationLevel.NoChanges, SignatureStatus.DisallowedChanges)]
    public void A_field_drawn_over_the_page_that_calls_itself_a_timestamp_is_a_change(CertificationLevel level, SignatureStatus expected)
    {
        using var pki = new LtvTestPki();
        var signed = SignBb(pki, certify: level);
        var forged = WithFakeTimestamp(signed, 50, 50, 350, 350, 4);
        Assert.True(PixelsChanged(signed, forged) > 0.05);
        Assert.Equal(expected, First(forged, pki).Status);
    }

    [Theory]
    [InlineData(CertificationLevel.None, SignatureStatus.ModifiedAfterSigning)]
    [InlineData(CertificationLevel.NoChanges, SignatureStatus.DisallowedChanges)]
    public void An_invisible_field_with_no_real_timestamp_in_it_is_a_change(CertificationLevel level, SignatureStatus expected)
    {
        using var pki = new LtvTestPki();
        var forged = WithFakeTimestamp(SignBb(pki, certify: level), 0, 0, 0, 0, 132);
        Assert.Equal(expected, First(forged, pki).Status);
    }

    [Theory]
    [InlineData(0, 0, 0, 0, 132)] // what we write
    [InlineData(100, 100, 100, 400, 4)] // no width
    [InlineData(50, 50, 350, 350, 2)] // hidden
    public void What_counts_as_an_invisible_field_really_draws_nothing(int x1, int y1, int x2, int y2, int flags)
    {
        using var pki = new LtvTestPki();
        var signed = SignBb(pki);
        Assert.Equal(0, PixelsChanged(signed, WithFakeTimestamp(signed, x1, y1, x2, y2, flags)));
    }

    private static byte[] WithDirectAnnotation(byte[] signed, string subtype)
    {
        using var doc = Signing.OpenForAppend(signed, null)!;
        PdfObj.Annots(doc, doc.Pages[0]).Elements.Add(Overlay(doc, subtype, 50, 50, 350, 350, 4));
        doc.Internals.Catalog.Elements["/DSS"] = new PdfDictionary(doc);
        return Incremental.TrySave(doc, null)!;
    }

    [Theory]
    [InlineData(CertificationLevel.None, "/Stamp", SignatureStatus.ModifiedAfterSigning)]
    [InlineData(CertificationLevel.NoChanges, "/Stamp", SignatureStatus.DisallowedChanges)]
    [InlineData(CertificationLevel.None, "/Widget", SignatureStatus.ModifiedAfterSigning)]
    [InlineData(CertificationLevel.NoChanges, "/Widget", SignatureStatus.DisallowedChanges)]
    public void An_annotation_written_inside_the_page_s_list_is_a_change(CertificationLevel level, string subtype, SignatureStatus expected)
    {
        using var pki = new LtvTestPki();
        var signed = SignBb(pki, certify: level);
        var forged = WithDirectAnnotation(signed, subtype);
        if (subtype == "/Stamp") Assert.True(PixelsChanged(signed, forged) > 0.05);
        Assert.Equal(expected, First(forged, pki).Status);
    }

    [Fact]
    public async Task An_annotation_inside_the_page_s_list_when_signed_doesn_t_get_in_the_way_of_validation_data()
    {
        using var pki = new LtvTestPki();
        byte[] pdf;
        using (var doc = PdfObj.Open(TestPdf.Make(2), null, PdfSharp.Pdf.IO.PdfDocumentOpenMode.Modify))
        {
            PdfObj.Annots(doc, doc.Pages[0]).Elements.Add(Overlay(doc, "/Stamp", 50, 50, 100, 100, 4));
            pdf = PdfObj.Save(doc, rewrite: true);
        }
        using var client = pki.Client();
        var extended = (await Ltv.AddVerificationAsync(SignBb(pki, pdf), null, client, client.TimestampSender(pki.TimestampUrl))).Pdf;
        var s = First(extended, pki);
        Assert.Equal(SignatureStatus.Valid, s.Status);
        Assert.True(s.LongTerm!.OnlyValidationDataAfter);
    }

    [Theory]
    [InlineData(8)]   // as many as a certificate's answers were looked at
    [InlineData(256)] // as many as the store holds
    public async Task Forged_answers_in_a_file_can_t_hide_what_the_server_said(int count)
    {
        using var pki = new LtvTestPki();
        using var forger = RSA.Create(2048);
        var signed = SignBb(pki);
        pki.Revoke(pki.Signer, DateTimeOffset.UtcNow.AddDays(-1));
        var request = LtvTestPki.OcspRequest(pki.Signer, pki.Intermediate);
        var forged = Enumerable.Range(0, count).Select(i => pki.OcspReply(request, forger, DateTimeOffset.UtcNow.AddMinutes(-i - 1))).ToList();
        var pdf = Dss.Append(signed, null, [new VriEntry("AA", [], forged, [])]);
        using var client = pki.Client();
        var online = await Ltv.CheckOnlineAsync(pdf, null, client);
        Assert.Contains(online.Certificates, c => c.Outcome.Contains("REVOKED"));
        Assert.Contains("Revoked", Signatures.Verify(pdf, null, online.Snapshot).First().CertificateStatus);
    }

    [Fact]
    public async Task Forged_answers_can_t_push_a_real_one_out_of_a_store()
    {
        using var pki = new LtvTestPki();
        using var forger = RSA.Create(2048);
        var signed = SignBb(pki);
        pki.Revoke(pki.Signer, DateTimeOffset.UtcNow.AddDays(-1));
        var request = LtvTestPki.OcspRequest(pki.Signer, pki.Intermediate);
        List<byte[]> answers = [.. Enumerable.Range(0, 8).Select(i => pki.OcspReply(request, forger, DateTimeOffset.UtcNow.AddMinutes(-i - 1))), pki.OcspReply(request)];
        var pdf = Dss.Append(signed, null, [new VriEntry("AA", [pki.Intermediate.RawData], answers, [])]);
        Assert.Contains("Revoked", First(pdf, pki).CertificateStatus);
    }

    [Fact]
    public async Task Slow_servers_don_t_use_up_the_time_a_file_is_given()
    {
        using var pki = new LtvTestPki();
        pki.Overrides["/ocsp"] = async body =>
        {
            await Task.Delay(TimeSpan.FromSeconds(11));
            return LtvTestPki.Http(200, pki.OcspReply(body));
        };
        using var client = pki.Client(TimeSpan.FromSeconds(15));
        var result = await Ltv.AddVerificationAsync(SignBb(pki), null, client); // two answers, 22 s in all
        Assert.All(result.Certificates, c => Assert.True(c.Covered, $"{c.Name}: {c.Outcome}"));
    }

    [Fact]
    public async Task Checking_online_asks_only_what_the_window_listed()
    {
        using var pki = new LtvTestPki();
        using var doc = Signing.OpenForAppend(SignBb(pki), null)!;
        doc.Pages[0].Elements["/Rotate"] = new PdfInteger(90);
        var changed = Incremental.TrySave(doc, null)!;
        Assert.Equal(SignatureStatus.DisallowedChanges, First(changed, pki).Status);
        using var client = pki.Client();
        Assert.Empty(Ltv.Plan(changed, null, client, onlyMissing: false).Addresses);
        await Ltv.CheckOnlineAsync(changed, null, client);
        Assert.Empty(pki.Hits);
    }

    private static byte[] CutOff() => "HTTP/1.1 200 X\r\nContent-Length: 1000\r\nConnection: close\r\n\r\nabc"u8.ToArray();

    [Fact]
    public async Task A_reply_cut_off_is_a_server_that_can_t_be_used()
    {
        using var pki = new LtvTestPki();
        pki.Overrides["/short"] = _ => Task.FromResult(CutOff());
        using var client = pki.Client();
        var ex = await Assert.ThrowsAsync<LtvFetchException>(() => client.GetAsync($"{pki.BaseUrl}/short", LtvAddressKind.Ocsp, LtvClient.MaxOcspReply));
        Assert.Contains("127.0.0.1", ex.Message);
    }

    [Fact]
    public async Task A_responder_s_reply_cut_off_leaves_the_crl_to_answer()
    {
        using var pki = new LtvTestPki();
        pki.Overrides["/ocsp"] = _ => Task.FromResult(CutOff());
        using var client = pki.Client();
        var result = await Ltv.AddVerificationAsync(SignBb(pki), null, client);
        Assert.All(result.Certificates, c => Assert.True(c.Covered, $"{c.Name}: {c.Outcome}"));
        Assert.Contains(result.Certificates, c => c.Outcome.Contains("CRL"));
    }

    // ---- Free and Pro ----

    [Fact]
    public void Adding_is_pro_and_verifying_stays_free()
    {
        Assert.NotEmpty(Pro.Title(ProFeature.LongTermValidation));
        Assert.Contains("long-term", Pro.Locked(ProFeature.LongTermValidation), StringComparison.OrdinalIgnoreCase);
        Assert.NotEmpty(Pro.Describe(ProFeature.LongTermValidation));
        // The check itself is the one every Pro feature asks: off while Pro isn't enforced.
        Assert.True(Pro.Allows(ProFeature.LongTermValidation));
    }
}
