using InkvoltPrint.Core.Suite;

namespace InkvoltPrint.Tests;

public class ShellRegistrationTests
{
    private const string Exe = @"C:\Users\someone\AppData\Local\Programs\Inkvolt Print\InkvoltPrint.exe";
    private const string OtherExe = @"D:\Portable\Inkvolt Print\InkvoltPrint.exe";

    /// <summary>HKCU in memory: key path → values (null name = default value). Keys are case-insensitive, like the registry.</summary>
    private sealed class FakeRegistry : IUserRegistry
    {
        public Dictionary<string, Dictionary<string, string>> Keys { get; } = new(StringComparer.OrdinalIgnoreCase);

        public void Set(string key, string? name, string value)
        {
            if (!Keys.TryGetValue(key, out var values)) Keys[key] = values = new(StringComparer.OrdinalIgnoreCase);
            values[name ?? ""] = value;
        }

        public bool KeyExists(string key) => Keys.ContainsKey(key);
        public string? GetString(string key, string? name) => Keys.TryGetValue(key, out var v) && v.TryGetValue(name ?? "", out var s) ? s : null;
        public bool ValueExists(string key, string name) => Keys.TryGetValue(key, out var v) && v.ContainsKey(name);
        public void DeleteValue(string key, string name) { if (Keys.TryGetValue(key, out var v)) v.Remove(name); }

        public void DeleteTree(string key)
        {
            foreach (var k in Keys.Keys.Where(k => k.Equals(key, StringComparison.OrdinalIgnoreCase) || k.StartsWith(key + @"\", StringComparison.OrdinalIgnoreCase)).ToList())
                Keys.Remove(k);
        }
    }

    /// <summary>What ShellIntegration and Start with Windows write for <paramref name="exe"/>.</summary>
    private static void Registered(FakeRegistry r, string exe)
    {
        var command = $"\"{exe}\" \"%1\"";
        foreach (var (progId, types) in new[] { (ShellRegistration.PdfProgId, ShellRegistration.PdfTypes), (ShellRegistration.ImageProgId, ShellRegistration.ImageTypes) })
        {
            var key = ShellRegistration.ProgIdKey(progId);
            r.Set(key, null, "type");
            r.Set(key + @"\DefaultIcon", null, $"\"{exe}\",0");
            r.Set(key + @"\shell\open", "FriendlyAppName", "Inkvolt Print");
            r.Set(ShellRegistration.CommandKey(key), null, command);
            foreach (var ext in types) r.Set(ShellRegistration.OpenWithKey(ext), progId, "");
        }
        r.Set(ShellRegistration.ApplicationKey, "FriendlyAppName", "Inkvolt Print");
        r.Set(ShellRegistration.ApplicationKey + @"\SupportedTypes", ".pdf", "");
        r.Set(ShellRegistration.CommandKey(ShellRegistration.ApplicationKey), null, command);
        r.Set(ShellRegistration.RunKey, ShellRegistration.RunValue, $"\"{exe}\" --background");
    }

    [Fact]
    public void Removes_everything_this_copy_wrote_and_nothing_else()
    {
        var r = new FakeRegistry();
        Registered(r, Exe);
        r.Set(ShellRegistration.OpenWithKey(".jpg"), "Photos.File", "");          // another app's "Open with"
        r.Set(ShellRegistration.RunKey, "OneDrive", @"""C:\OneDrive.exe"" /background");
        r.Set(@"Software\Classes\.jpg", null, "jpegfile");

        var removed = ShellRegistration.Unregister(r, Exe);

        Assert.False(r.KeyExists(ShellRegistration.ProgIdKey(ShellRegistration.PdfProgId)));
        Assert.False(r.KeyExists(ShellRegistration.ProgIdKey(ShellRegistration.ImageProgId) + @"\shell\open\command"));
        Assert.False(r.KeyExists(ShellRegistration.ApplicationKey + @"\SupportedTypes"));
        Assert.False(r.ValueExists(ShellRegistration.RunKey, ShellRegistration.RunValue));
        Assert.All(ShellRegistration.ImageTypes, ext => Assert.False(r.ValueExists(ShellRegistration.OpenWithKey(ext), ShellRegistration.ImageProgId)));
        Assert.False(r.ValueExists(ShellRegistration.OpenWithKey(".pdf"), ShellRegistration.PdfProgId));
        Assert.True(r.ValueExists(ShellRegistration.OpenWithKey(".jpg"), "Photos.File"));
        Assert.True(r.ValueExists(ShellRegistration.RunKey, "OneDrive"));
        Assert.Equal("jpegfile", r.GetString(@"Software\Classes\.jpg", null));
        Assert.Equal(2 + 1 + 9 + 1 + 1, removed.Count); // 2 ProgIds, .pdf, 9 picture types, Applications, Run
    }

    [Fact]
    public void Another_copys_entries_are_kept()
    {
        var r = new FakeRegistry();
        Registered(r, OtherExe);
        Assert.Empty(ShellRegistration.Unregister(r, Exe));
        Assert.True(r.KeyExists(ShellRegistration.ProgIdKey(ShellRegistration.ImageProgId)));
        Assert.True(r.ValueExists(ShellRegistration.OpenWithKey(".png"), ShellRegistration.ImageProgId));
        Assert.True(r.KeyExists(ShellRegistration.ApplicationKey));
        Assert.True(r.ValueExists(ShellRegistration.RunKey, ShellRegistration.RunValue));
    }

    [Fact]
    public void Entries_left_by_a_removed_ProgId_go_too()
    {
        var r = new FakeRegistry();
        r.Set(ShellRegistration.OpenWithKey(".pdf"), ShellRegistration.PdfProgId, "");
        r.Set(ShellRegistration.OpenWithKey(".heic"), ShellRegistration.ImageProgId, "");
        ShellRegistration.Unregister(r, Exe);
        Assert.False(r.ValueExists(ShellRegistration.OpenWithKey(".pdf"), ShellRegistration.PdfProgId));
        Assert.False(r.ValueExists(ShellRegistration.OpenWithKey(".heic"), ShellRegistration.ImageProgId));
    }

    [Fact]
    public void Nothing_registered_nothing_removed() => Assert.Empty(ShellRegistration.Unregister(new FakeRegistry(), Exe));

    [Fact]
    public void The_toast_identity_goes_with_the_copy_that_wrote_it_and_stays_for_another()
    {
        var r = new FakeRegistry();
        r.Set(ShellRegistration.AppUserModelIdKey, "DisplayName", "Inkvolt Print");
        r.Set(ShellRegistration.AppUserModelIdKey, "IconUri", @"C:\Users\someone\AppData\Local\InkvoltPrint\InkvoltPrint.ico");
        r.Set(ShellRegistration.AppUserModelIdKey, ShellRegistration.AppUserModelIdExeValue, OtherExe);
        Assert.Empty(ShellRegistration.Unregister(r, Exe));
        Assert.True(r.KeyExists(ShellRegistration.AppUserModelIdKey));

        r.Set(ShellRegistration.AppUserModelIdKey, ShellRegistration.AppUserModelIdExeValue, Exe);
        Assert.Equal([ShellRegistration.AppUserModelIdKey], ShellRegistration.Unregister(r, Exe));
        Assert.False(r.KeyExists(ShellRegistration.AppUserModelIdKey));
    }

    [Fact]
    public void Matching_ignores_case_and_slashes() =>
        Assert.True(ShellRegistration.PointsAt($"\"{Exe.ToUpperInvariant().Replace('\\', '/')}\" --background", Exe));

    [Theory]
    [InlineData(@"""C:\Program Files\Inkvolt Print\InkvoltPrint.exe"" ""%1""", @"C:\Program Files\Inkvolt Print\InkvoltPrint.exe")]
    [InlineData(@"C:\Tools\InkvoltPrint.exe --background", @"C:\Tools\InkvoltPrint.exe")]
    [InlineData(@"C:\Tools\app.cmd", @"C:\Tools\app.cmd")]
    [InlineData(@"""", null)]
    [InlineData("", null)]
    [InlineData(null, null)]
    public void Command_exe(string? command, string? expected) => Assert.Equal(expected, ShellRegistration.CommandExe(command));

    private const string DevExe = @"Z:\Src\InkvoltPrint\publish\InkvoltPrint.exe";

    [Fact]
    public void Another_copy_never_takes_over_an_existing_installed_copys_entries()
    {
        var r = new FakeRegistry();
        Registered(r, Exe);

        Assert.False(ShellRegistration.MayRegister(r, DevExe, [Exe], _ => true));
    }

    [Fact]
    public void Another_copy_takes_over_entries_whose_exe_is_gone()
    {
        var r = new FakeRegistry();
        Registered(r, OtherExe);

        Assert.True(ShellRegistration.MayRegister(r, DevExe, [Exe], path => path != OtherExe));
    }

    [Fact]
    public void The_installed_copy_always_registers()
    {
        var r = new FakeRegistry();
        Registered(r, OtherExe);

        Assert.True(ShellRegistration.MayRegister(r, Exe.ToUpperInvariant(), [Exe], _ => true));
    }

    [Fact]
    public void Any_copy_registers_when_nothing_is_registered_or_the_entries_are_its_own()
    {
        var r = new FakeRegistry();
        Assert.True(ShellRegistration.MayRegister(r, DevExe, [Exe], _ => true));

        Registered(r, DevExe);
        Assert.True(ShellRegistration.MayRegister(r, DevExe, [Exe], _ => true));
    }

    [Fact]
    public void A_second_copy_that_did_not_register_unregisters_nothing_of_the_installed_copy()
    {
        // The tester's case: the installed copy registered, a copy from another folder ran, then that copy's --unregister.
        var r = new FakeRegistry();
        Registered(r, Exe);
        r.DeleteValue(ShellRegistration.RunKey, ShellRegistration.RunValue);

        Assert.False(ShellRegistration.MayRegister(r, DevExe, [Exe], _ => true));
        Assert.Empty(ShellRegistration.Unregister(r, DevExe));
        Assert.True(r.KeyExists(ShellRegistration.ProgIdKey(ShellRegistration.PdfProgId)));
    }
}
