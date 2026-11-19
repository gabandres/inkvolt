using System.Security.Cryptography;
using System.Security.Cryptography.X509Certificates;
using InkvoltPrint.Core.Sharing;

namespace InkvoltPrint.Windows.Sharing;

/// <summary>
/// The shared scanner's certificate, kept per install (roadmap 3.1). Its private key is an ECDSA P-256 key in the user's own key store
/// (CNG's Microsoft Software Key Storage Provider, protected by Windows for this user, not exportable: it never sits in a file of the
/// app's or in the repo); the certificate itself, which is public, is a file next to the app's settings. Made on first use, and anew
/// when it nears its end, when the PC's name changed, or when the file doesn't match the key. No administrator rights.
/// </summary>
/// <param name="folder">Where the certificate file goes (the app's data folder).</param>
/// <param name="keyName">The key's name in the user's key store.</param>
public sealed class ShareCertificateStore(string folder, string keyName = ShareCertificateStore.KeyName) : IShareCertificates
{
    public const string KeyName = "Inkvolt Print scanner sharing";
    public const string FileName = "scanner-sharing.cer";

    public X509Certificate2 Get(string hostName, DateTimeOffset now)
    {
        using var key = OpenOrCreate(keyName);
        using var ecdsa = new ECDsaCng(key);
        var path = Path.Combine(folder, FileName);
        using (var kept = Read(path))
        {
            if (kept is not null && ShareCertificate.Usable(kept, now) && SameKey(kept, ecdsa) && Names(kept).Contains(hostName, StringComparer.OrdinalIgnoreCase))
                return kept.CopyWithPrivateKey(ecdsa);
        }
        var made = ShareCertificate.Create(ecdsa, hostName, now);
        Directory.CreateDirectory(folder);
        var temp = path + ".tmp";
        File.WriteAllBytes(temp, made.RawData);
        File.Move(temp, path, overwrite: true);
        return made;
    }

    /// <summary>Forgets the key and the certificate (a new one, with a new fingerprint, is made on the next share).</summary>
    public void Remove()
    {
        try
        {
            if (CngKey.Exists(keyName)) CngKey.Open(keyName).Delete();
        }
        catch (CryptographicException) { }
        try { File.Delete(Path.Combine(folder, FileName)); }
        catch (IOException) { }
    }

    private static CngKey OpenOrCreate(string name)
    {
        if (CngKey.Exists(name)) return CngKey.Open(name);
        return CngKey.Create(CngAlgorithm.ECDsaP256, name, new CngKeyCreationParameters
        {
            Provider = CngProvider.MicrosoftSoftwareKeyStorageProvider,
            ExportPolicy = CngExportPolicies.None,
            KeyUsage = CngKeyUsages.Signing,
            KeyCreationOptions = CngKeyCreationOptions.None, // the user's store, not the machine's
        });
    }

    private static X509Certificate2? Read(string path)
    {
        try
        {
            return File.Exists(path) ? X509CertificateLoader.LoadCertificateFromFile(path) : null;
        }
        catch (Exception ex) when (ex is CryptographicException or IOException or UnauthorizedAccessException)
        {
            return null; // made anew
        }
    }

    private static bool SameKey(X509Certificate2 cert, ECDsa key)
    {
        using var mine = cert.GetECDsaPublicKey();
        if (mine is null) return false;
        var a = mine.ExportParameters(false).Q;
        var b = key.ExportParameters(false).Q;
        return a.X is not null && b.X is not null && a.X.AsSpan().SequenceEqual(b.X) && a.Y.AsSpan().SequenceEqual(b.Y);
    }

    private static IEnumerable<string> Names(X509Certificate2 cert) =>
        cert.Extensions.Where(e => e.Oid?.Value == "2.5.29.17")
            .SelectMany(e => new X509SubjectAlternativeNameExtension(e.RawData, e.Critical).EnumerateDnsNames());
}
