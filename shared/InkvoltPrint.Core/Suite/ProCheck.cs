namespace InkvoltPrint.Core.Suite;

/// <summary>
/// The Pro entitlement check behind each app's <c>Pro</c> (Inkvolt PDF's in InkvoltPdf.Core, Inkvolt Print's in
/// InkvoltPrint.Core): one instance per app, for its product. The licence is a key (<see cref="ProKeys"/>) signed with our
/// private key and checked here against the public key: no server is asked, nothing is sent, the key works offline and
/// survives reinstalling. It is kept where both apps find it (<see cref="ProKeyFile"/>) and in the app's own settings, so
/// a key entered in one app licenses the other when it lists both products. Removing it never takes away a result
/// already made.
/// </summary>
public sealed class ProCheck(string product)
{
    /// <summary>
    /// The one switch, for both apps. While it is false, everything is free: <see cref="Allowed"/> says yes to everyone (a
    /// key is still verified and shown in Help › Inkvolt Pro, and the purchase is a way to support the project or to get a
    /// licence a business can invoice). It flips to true, in a release noted in each app's WHATS-NEW, once Inkvolt PDF has
    /// a few thousand installs or about 50 Store ratings; from then on the Pro features ask for a key. Tests set it either way.
    /// </summary>
    public static bool Enforced { get; internal set; }

    public const string PriceText = "$19";
    public const string BuyUrl = "https://bermudezsystems.com/products/inkvolt/pro";

    private readonly Lock _gate = new();
    private IProStore _store = new MemoryProStore();
    private ProLicence? _licence;
    private string? _problem;
    private bool _loaded;

    /// <summary>"pdf" or "print" (<see cref="ProKeys.KnownProducts"/>): what a key must list to count here.</summary>
    public string Product { get; } = product;

    /// <summary>The app, as the refusals name it.</summary>
    public string ProductName => ProKeys.ProductName(Product);

    /// <summary>Where the key is kept. Setting it forgets what was read from the previous store.</summary>
    public IProStore Store
    {
        get => _store;
        set
        {
            lock (_gate)
            {
                _store = value;
                _loaded = false;
            }
        }
    }

    /// <summary>The installed licence, or null (none, or the stored key doesn't count: <see cref="Problem"/>).</summary>
    public ProLicence? Licence
    {
        get
        {
            lock (_gate)
            {
                Load();
                return _licence;
            }
        }
    }

    /// <summary>Why the stored key doesn't count, when there is one and it doesn't; null otherwise.</summary>
    public string? Problem
    {
        get
        {
            lock (_gate)
            {
                Load();
                return _problem;
            }
        }
    }

    /// <summary>True when a Pro feature may run: always while <see cref="Enforced"/> is off, else with a licence.</summary>
    public bool Allowed => !Enforced || Licence is not null;

    /// <summary>Checks <paramref name="key"/>, keeps it in the <see cref="Store"/> and returns its licence; refuses with a reason.</summary>
    public ProLicence Install(string key)
    {
        var licence = ProKeys.Parse(key);
        if (!licence.Covers(Product))
            throw new ProKeyException($"This key is for {Names(licence)}, not {ProductName}. A key for {ProductName} lists it.");
        lock (_gate)
        {
            _store.Write(ProKeys.Format(key));
            _licence = licence;
            _problem = null;
            _loaded = true;
        }
        return licence;
    }

    /// <summary>Forgets the key. What the Pro features made stays.</summary>
    public void Remove()
    {
        lock (_gate)
        {
            _store.Write(null);
            _licence = null;
            _problem = null;
            _loaded = true;
        }
    }

    private void Load()
    {
        if (_loaded) return;
        _loaded = true;
        _licence = null;
        _problem = null;
        if (_store.Read() is not { Length: > 0 } stored) return;
        try
        {
            var licence = ProKeys.Parse(stored);
            if (licence.Covers(Product)) _licence = licence;
            else _problem = $"The saved key is for {Names(licence)}, not {ProductName}.";
        }
        catch (ProKeyException ex)
        {
            _problem = $"The saved key no longer checks out: {ex.Message}";
        }
    }

    private static string Names(ProLicence licence) => string.Join(" and ", licence.Products.Select(ProKeys.ProductName));
}
