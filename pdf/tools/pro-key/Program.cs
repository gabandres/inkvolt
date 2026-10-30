using System.Security.Cryptography;
using InkvoltPrint.Core.Suite;

// The Inkvolt Pro licence tool: keygen | issue | check. README.md says how; the private key never leaves the key folder
// and is never printed.
return args.Length == 0 ? Usage() : args[0] switch
{
    "keygen" => Keygen(args),
    "issue" => Issue(args),
    "check" => Check(args),
    _ => Usage(),
};

static int Usage()
{
    Console.Error.WriteLine("""
        pro-key: the Inkvolt Pro licence tool (no key material is ever printed)

          dotnet run -- keygen [--dir <folder>]
              Makes the P-256 pair: inkvolt-pro.key (PRIVATE, PKCS#8 PEM) and inkvolt-pro.pub (the public point, base64)
              in %USERPROFILE%\.inkvolt-pro (or --dir). Refuses to overwrite. Prints the public key for ProKeys.PublicKeyBase64.
          dotnet run -- issue --name "Full Name" --email who@example.com [--date yyyy-MM-dd] [--products pdf,print] [--dir <folder>]
              Prints a licence key (today's date, product pdf unless given).
          dotnet run -- check <key> [--pub <base64>]
              Reads a key against the public key built into the Inkvolt apps (or --pub) and prints what it says, or why it is refused.
        """);
    return 2;
}

static string? Option(string[] args, string name)
{
    var i = Array.IndexOf(args, name);
    return i >= 0 && i + 1 < args.Length ? args[i + 1] : null;
}

static string KeyDir(string[] args) => Option(args, "--dir") ?? Path.Combine(Environment.GetFolderPath(Environment.SpecialFolder.UserProfile), ".inkvolt-pro");

static int Keygen(string[] args)
{
    var dir = KeyDir(args);
    var keyPath = Path.Combine(dir, "inkvolt-pro.key");
    var pubPath = Path.Combine(dir, "inkvolt-pro.pub");
    if (File.Exists(keyPath) || File.Exists(pubPath))
    {
        Console.Error.WriteLine($"There is a key in {dir} already; not touching it. Move it away first if you mean to rotate.");
        return 1;
    }
    Directory.CreateDirectory(dir);
    using var ecdsa = ECDsa.Create(ECCurve.NamedCurves.nistP256);
    var pub = PublicPoint(ecdsa);
    File.WriteAllText(keyPath, ecdsa.ExportPkcs8PrivateKeyPem() + "\n");
    File.WriteAllText(pubPath, pub + "\n");
    Console.WriteLine($"Private key written to {keyPath} (keep it out of the repo; back it up as README.md says).");
    Console.WriteLine($"Public key written to {pubPath}. Put this in InkvoltPrint.Core/Suite/ProKeys.cs as ProKeys.PublicKeyBase64:");
    Console.WriteLine(pub);
    return 0;
}

static string PublicPoint(ECDsa ecdsa)
{
    var q = ecdsa.ExportParameters(false).Q;
    return Convert.ToBase64String([4, .. q.X!, .. q.Y!]);
}

static int Issue(string[] args)
{
    var name = Option(args, "--name");
    var email = Option(args, "--email");
    if (name is null || email is null)
    {
        Console.Error.WriteLine("issue needs --name and --email.");
        return 2;
    }
    var date = Option(args, "--date") is { } d ? DateOnly.ParseExact(d, "yyyy-MM-dd") : DateOnly.FromDateTime(DateTime.Today);
    var products = (Option(args, "--products") ?? ProKeys.ProductPdf).Split(',', StringSplitOptions.RemoveEmptyEntries | StringSplitOptions.TrimEntries);
    var keyPath = Path.Combine(KeyDir(args), "inkvolt-pro.key");
    if (!File.Exists(keyPath))
    {
        Console.Error.WriteLine($"No private key at {keyPath}: keygen first, or --dir where it is.");
        return 1;
    }
    using var ecdsa = ECDsa.Create();
    ecdsa.ImportFromPem(File.ReadAllText(keyPath));
    if (PublicPoint(ecdsa) != ProKeys.PublicKeyBase64)
        Console.Error.WriteLine("Warning: this private key doesn't match the public key built into the Inkvolt apps; the key it issues won't be accepted there.");
    try
    {
        Console.WriteLine(ProKeys.Issue(new ProLicence(name, email, date, products), ecdsa));
        return 0;
    }
    catch (ArgumentException ex)
    {
        Console.Error.WriteLine(ex.Message);
        return 2;
    }
}

static int Check(string[] args)
{
    if (args.Length < 2)
    {
        Console.Error.WriteLine("check needs the key.");
        return 2;
    }
    var pub = Option(args, "--pub") is { } p ? Convert.FromBase64String(p) : ProKeys.PublicKey;
    try
    {
        var licence = ProKeys.Parse(args[1], pub);
        Console.WriteLine($"Valid. Licensed to {licence.Name} <{licence.Email}>, issued {licence.Issued:yyyy-MM-dd}, products: {string.Join(", ", licence.Products)}.");
        return 0;
    }
    catch (ProKeyException ex)
    {
        Console.WriteLine($"Refused: {ex.Message}");
        return 1;
    }
}
