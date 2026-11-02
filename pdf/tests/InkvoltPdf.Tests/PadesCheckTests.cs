using System.Diagnostics;
using InkvoltPdf.Core;

namespace InkvoltPdf.Tests;

/// <summary>
/// The EU DSS validator's view of our signed files (roadmap 3.4's test), run on this PC with no online source: see
/// pdf/tools/pades-check/README.md. Opt-in with INKVOLTPDF_PADES_CHECK set; needs Java and the tool's libraries. Set
/// INKVOLTPDF_PADES_KEEP to a folder to keep the files and the validator's output there.
/// </summary>
public class PadesCheckTests
{
    private static string ToolFolder()
    {
        var dir = new DirectoryInfo(AppContext.BaseDirectory);
        while (dir is not null && !Directory.Exists(Path.Combine(dir.FullName, "pdf", "tools", "pades-check"))) dir = dir.Parent;
        return dir is null ? "" : Path.Combine(dir.FullName, "pdf", "tools", "pades-check");
    }

    private static string Validate(string tool, string file, string root)
    {
        var start = new ProcessStartInfo("java") { WorkingDirectory = tool, RedirectStandardOutput = true, RedirectStandardError = true };
        start.ArgumentList.Add("-cp");
        start.ArgumentList.Add(Path.Combine(".cache", "lib", "*"));
        start.ArgumentList.Add("PadesCheck.java");
        start.ArgumentList.Add(file);
        start.ArgumentList.Add(root);
        using var java = Process.Start(start)!;
        var err = java.StandardError.ReadToEndAsync();
        var output = java.StandardOutput.ReadToEnd();
        Assert.True(java.WaitForExit(180_000), "The validator didn't finish");
        Assert.True(java.ExitCode == 0, $"The validator failed: {err.Result}");
        return output;
    }

    [Fact]
    public async Task Eu_dss_reports_the_levels_we_claim()
    {
        if (Environment.GetEnvironmentVariable("INKVOLTPDF_PADES_CHECK") is not { Length: > 0 }) return;
        var tool = ToolFolder();
        Assert.True(Directory.Exists(Path.Combine(tool, ".cache", "lib")), "Fetch the libraries first (pdf/tools/pades-check/README.md)");
        var keep = Environment.GetEnvironmentVariable("INKVOLTPDF_PADES_KEEP");
        var folder = keep ?? Path.Combine(Path.GetTempPath(), "pades-check-" + Guid.NewGuid().ToString("N"));
        Directory.CreateDirectory(folder);
        try
        {
            using var pki = new LtvTestPki();
            using var client = pki.Client();
            var root = Path.Combine(folder, "root.cer");
            await File.WriteAllBytesAsync(root, pki.Root.RawData);
            var stamp = client.TimestampSender(pki.TimestampUrl);
            var signer = pki.Signer;
            var files = new Dictionary<string, (byte[] Pdf, string Format)>
            {
                ["b-b"] = (Signing.Sign(TestPdf.Make(1), null, new SignRequest { Certificate = signer }), "PAdES-BASELINE-B"),
                ["b-t"] = (await Signing.SignAsync(TestPdf.Make(1), null, new SignRequest { Certificate = signer, Timestamp = stamp }), "PAdES-BASELINE-T"),
                ["b-lt"] = (await Signing.SignAsync(TestPdf.Make(1), null, new SignRequest { Certificate = signer, Timestamp = stamp, LongTerm = LongTermLevel.Lt, LongTermClient = client }), "PAdES-BASELINE-LT"),
                ["b-lta"] = (await Signing.SignAsync(TestPdf.Make(1), null, new SignRequest { Certificate = signer, Timestamp = stamp, LongTerm = LongTermLevel.Lta, LongTermClient = client }), "PAdES-BASELINE-LTA"),
                ["added-to-b-b"] = ((await Ltv.AddVerificationAsync(Signing.Sign(TestPdf.Make(2), null, new SignRequest { Certificate = signer }), null, client, stamp)).Pdf, "PAdES-BASELINE-LTA"),
                ["certified-no-changes"] = ((await Ltv.AddVerificationAsync(Signing.Sign(TestPdf.Make(1), null, new SignRequest { Certificate = signer, Certify = CertificationLevel.NoChanges }), null, client, stamp)).Pdf, "PAdES-BASELINE-LTA"),
            };
            pki.Overrides["/ocsp"] = _ => Task.FromResult(LtvTestPki.Http(503, []));
            files["crls-only"] = (await Signing.SignAsync(TestPdf.Make(1), null, new SignRequest { Certificate = signer, Timestamp = stamp, LongTerm = LongTermLevel.Lta, LongTermClient = client }), "PAdES-BASELINE-LTA");
            pki.Overrides.Remove("/ocsp");
            pki.DelegateOcsp = true;
            files["delegated-responder"] = (await Signing.SignAsync(TestPdf.Make(1), null, new SignRequest { Certificate = signer, Timestamp = stamp, LongTerm = LongTermLevel.Lta, LongTermClient = client }), "PAdES-BASELINE-LTA");

            var problems = new List<string>();
            foreach (var (name, (pdf, format)) in files)
            {
                var path = Path.Combine(folder, name + ".pdf");
                await File.WriteAllBytesAsync(path, pdf);
                var report = Validate(tool, path, root);
                await File.WriteAllTextAsync(Path.Combine(folder, name + ".txt"), report);
                var first = report.Split('\n').First(l => l.StartsWith("SIGNATURE ", StringComparison.Ordinal)).Trim();
                if (!first.StartsWith($"SIGNATURE {format} ", StringComparison.Ordinal)) problems.Add($"{name}: expected {format}, got: {report}");
                // A signature with long-term data must pass with nothing but what the file holds; the plainer ones have no way to.
                if (format is "PAdES-BASELINE-LT" or "PAdES-BASELINE-LTA" && !first.Contains("TOTAL_PASSED", StringComparison.Ordinal)) problems.Add($"{name}: didn't pass: {report}");
            }
            Assert.True(problems.Count == 0, string.Join("\n\n", problems));
        }
        finally
        {
            if (keep is null) Directory.Delete(folder, recursive: true);
        }
    }

    /// <summary>
    /// Drives the built app against the local authority: Add Verification Information, Check Signatures Online and signing
    /// for B-LTA, from their windows on. Opt-in with INKVOLTPDF_LTV_APP naming InkvoltPdf.exe; its shots and files go to
    /// INKVOLTPDF_PADES_KEEP or a temporary folder.
    /// </summary>
    [Fact]
    public async Task The_real_app_adds_checks_and_signs()
    {
        if (Environment.GetEnvironmentVariable("INKVOLTPDF_LTV_APP") is not { Length: > 0 } exe) return;
        var folder = Path.Combine(Environment.GetEnvironmentVariable("INKVOLTPDF_PADES_KEEP") ?? Path.GetTempPath(), "app-run");
        if (Directory.Exists(folder)) Directory.Delete(folder, recursive: true);
        Directory.CreateDirectory(folder);
        using var pki = new LtvTestPki();
        var signed = Path.Combine(folder, "signed.pdf");
        await File.WriteAllBytesAsync(signed, Signing.Sign(TestPdf.Make(2), null, new SignRequest { Certificate = pki.Signer, Reason = "Approved", PageIndex = 0, Rect = new RectD(72, 600, 240, 70) }));
        await File.WriteAllBytesAsync(Path.Combine(folder, "plain.pdf"), TestPdf.Make(1));
        var pfx = Path.Combine(folder, "signer.pfx");
        await File.WriteAllBytesAsync(pfx, pki.Signer.Export(System.Security.Cryptography.X509Certificates.X509ContentType.Pkcs12, "pw"));
        var f = folder.Replace('\\', '/');
        var steps = Path.Combine(folder, "steps.txt");
        await File.WriteAllLinesAsync(steps,
        [
            $"ltvloopback {pki.TimestampUrl}",
            "levels",
            "pane signatures",
            "wait 500",
            $"shot {f}/1-pane-before.png",
            "focus",
            "a11yaudit",
            $"later 2500 dialogshot {f}/2-add-window.png",
            "later 3000 a11yaudit",
            "later 3300 dialogfill check0=on",
            $"later 3800 dialogshot {f}/3-add-window-timestamp.png",
            "later 4300 dialogbutton Contact{sp}and{sp}add",
            $"savepath {f}/added-ltv.pdf",
            "addvri",
            "wait 800",
            "levels",
            $"shot {f}/4-pane-after.png",
            $"later 2500 dialogshot {f}/5-online-window.png",
            "later 3200 dialogbutton Contact{sp}and{sp}check",
            "checkonline",
            "wait 1000",
            "levels",
            $"shot {f}/6-pane-online.png",
            $"later 1800 dialogshot {f}/7-sign-window.png",
            "later 2400 closedialog",
            "cmd Sign",
            "wait 800",
            "proenforce on",
            $"later 1500 dialogshot {f}/8-pro-window.png",
            "later 2000 closedialog",
            "cmd AddVerification",
            "wait 800",
            "proenforce off",
            $"open {f}/plain.pdf",
            "wait 1500",
            $"later 2500 dialogshot {f}/9-sign-consent.png",
            "later 3200 dialogbutton Contact{sp}and{sp}sign",
            $"savepath {f}/signed-lta.pdf",
            $"sign {pfx.Replace('\\', '/')} pw invisible ts {pki.TimestampUrl} lta",
            "wait 1000",
            "levels",
            "sigs",
            $"shot {f}/10-signed-lta.png",
            "exit",
        ]);
        var start = new ProcessStartInfo(exe) { UseShellExecute = false };
        start.ArgumentList.Add(signed);
        start.ArgumentList.Add("--script");
        start.ArgumentList.Add(steps);
        start.Environment["INKVOLTPDF_DEVSCRIPT"] = "1";
        using var app = Process.Start(start)!;
        using var limit = new CancellationTokenSource(TimeSpan.FromMinutes(4));
        await app.WaitForExitAsync(limit.Token);
        var log = await File.ReadAllTextAsync(steps + ".log");
        Assert.DoesNotContain("FAILED", log);
        var added = await File.ReadAllBytesAsync(Path.Combine(folder, "added-ltv.pdf"));
        Assert.Equal(PadesLevel.BLTA, Signatures.Verify(added, null, pki.Anchors).First(s => s.SubFilter != "ETSI.RFC3161").LongTerm!.Level);
        var lta = await File.ReadAllBytesAsync(Path.Combine(folder, "signed-lta.pdf"));
        Assert.Equal(PadesLevel.BLTA, Signatures.Verify(lta, null, pki.Anchors).First(s => s.SubFilter != "ETSI.RFC3161").LongTerm!.Level);
    }
}
