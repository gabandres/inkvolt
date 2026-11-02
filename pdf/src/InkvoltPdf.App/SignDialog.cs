using System.IO;
using System.Security.Cryptography;
using System.Security.Cryptography.X509Certificates;
using System.Windows;
using System.Windows.Controls;
using System.Windows.Media;
using System.Windows.Media.Imaging;
using Microsoft.Win32;
using InkvoltPdf.Core;

namespace InkvoltPdf.App;

/// <summary>What the user chose in the Sign dialog.</summary>
public sealed record SignChoice(
    X509Certificate2 Certificate,
    string? Reason,
    string? Location,
    bool Visible,
    SignatureLook Look,
    bool Timestamp,
    string TimestampUrl,
    CertificationLevel Certify,
    LongTermLevel LongTerm = LongTermLevel.None);

/// <summary>
/// "Sign Digitally": pick a digital ID (Windows certificate store, a .pfx file, or a new personal ID), reason, location,
/// the visible signature's look (live preview), timestamp and certification.
/// </summary>
public static class SignDialog
{
    private sealed class IdItem(string label, X509Certificate2? cert = null, Func<X509Certificate2?>? action = null)
    {
        public string Label { get; } = label;
        public X509Certificate2? Cert { get; set; } = cert;
        public Func<X509Certificate2?>? Action { get; } = action;
        public override string ToString() => Label;
    }

    private static readonly string[] Reasons =
    [
        "I am the author of this document",
        "I approve this document",
        "I have reviewed this document",
        "I agree to the terms defined by this document",
    ];

    /// <param name="fieldAspect">Width/height of the box the signature goes in (an existing field's), for the preview.</param>
    public static SignChoice? Show(Window owner, string? fieldName, double fieldAspect, bool fieldVisible, bool alreadySigned)
    {
        var s = AppSettings.Current;
        var dlg = new FormDialog(owner, fieldName is null ? "Sign digitally" : $"Sign \"{fieldName}\"", "Sign…", 520);
        var items = new System.Collections.ObjectModel.ObservableCollection<IdItem>();
        try
        {
            foreach (var c in DigitalIds.ListUsable()) items.Add(new IdItem(DigitalIds.Describe(c), c));
        }
        catch (CryptographicException ex)
        {
            Log.Write($"Listing digital IDs failed: {ex.Message}");
        }
        items.Add(new IdItem("Use a digital ID file (.pfx, .p12)…", action: () => LoadPfx(dlg)));
        items.Add(new IdItem("Create a personal digital ID…", action: () => CreatePersonal(dlg)));

        var ids = new ComboBox { ItemsSource = items };
        var last = items.ToList().FindIndex(i => i.Cert?.Thumbprint == s.SignThumbprint);
        ids.SelectedIndex = last >= 0 ? last : items[0].Cert is not null ? 0 : -1;
        var prev = ids.SelectedIndex;
        dlg.Add("Digital ID", ids);
        var idNote = dlg.AddNote("");
        Action refresh = () => { };
        void DescribeId()
        {
            var c = (ids.SelectedItem as IdItem)?.Cert;
            idNote.Text = c is null
                ? "Choose a digital ID. Smart cards and Windows Hello keys ask for their PIN when you sign."
                : $"{c.Subject}{Environment.NewLine}Issued by {c.GetNameInfo(X509NameType.SimpleName, true)}; valid until {c.NotAfter:d}.";
        }
        ids.SelectionChanged += (_, _) =>
        {
            if (ids.SelectedItem is IdItem { Cert: null, Action: { } act })
            {
                var made = act();
                if (made is null)
                {
                    ids.SelectedIndex = prev;
                    return;
                }
                var added = new IdItem(DigitalIds.Describe(made), made);
                items.Insert(0, added);
                ids.SelectedItem = added;
            }
            prev = ids.SelectedIndex;
            DescribeId();
            refresh();
        };

        var reason = dlg.Add("Reason", new ComboBox { IsEditable = true, ItemsSource = Reasons, Text = s.SignReason });
        var location = dlg.AddText("Location", s.SignLocation);

        var visible = dlg.AddCheck("Show the signature on the page", fieldName is null ? s.SignVisible : fieldVisible);
        visible.IsEnabled = fieldName is null;
        var shown = dlg.Add(null, new WrapPanel());
        CheckBox ShowCheck(string text, bool value)
        {
            var box = new CheckBox { Content = text, IsChecked = value, Margin = new Thickness(0, 0, 16, 0) };
            shown.Children.Add(box);
            return box;
        }
        var showDate = ShowCheck("Show the date", s.SignShowDate);
        var showReason = ShowCheck("Show the reason", s.SignShowReason);
        var showDn = ShowCheck("Show the distinguished name", s.SignShowDn);
        var saved = SignatureLibrary.List().Where(x => !x.Initials).ToList();
        var imageNames = new List<string> { "No image" };
        imageNames.AddRange(saved.Select(x => $"Handwritten: {x.Name}"));
        var imageIndex = saved.FindIndex(x => x.Path == s.SignImage) + 1;
        var image = dlg.AddChoice("Image beside the text", imageNames, imageIndex);

        // Live preview of the visible signature: details left, handwriting right.
        var aspect = Math.Clamp(fieldAspect, 1.2, 6);
        var previewText = new StackPanel { VerticalAlignment = VerticalAlignment.Center, Margin = new Thickness(6, 4, 6, 4) };
        var previewImage = new Image { Stretch = Stretch.Uniform, Margin = new Thickness(4) };
        var grid = new Grid { Background = Brushes.White };
        grid.ColumnDefinitions.Add(new ColumnDefinition());
        grid.ColumnDefinitions.Add(new ColumnDefinition { Width = GridLength.Auto });
        grid.Children.Add(new Viewbox { Child = previewText, Stretch = Stretch.Uniform, StretchDirection = StretchDirection.Both, HorizontalAlignment = HorizontalAlignment.Left });
        Grid.SetColumn(previewImage, 1);
        grid.Children.Add(previewImage);
        var preview = dlg.Add("Preview", new Border { Child = grid, Width = 320, Height = 320 / aspect, HorizontalAlignment = HorizontalAlignment.Left, BorderBrush = Brushes.Gray, BorderThickness = new Thickness(1) });

        void UpdatePreview()
        {
            var c = (ids.SelectedItem as IdItem)?.Cert;
            var name = c?.GetNameInfo(X509NameType.SimpleName, false) ?? "Your name";
            previewText.Children.Clear();
            void Line(string t) => previewText.Children.Add(new TextBlock { Text = t, Foreground = Brushes.Black, FontFamily = new FontFamily("Arial"), FontSize = 11 });
            Line($"Digitally signed by {name}");
            if (showDn.IsChecked == true && c is not null) Line($"DN: {c.Subject}");
            if (showReason.IsChecked == true && !string.IsNullOrWhiteSpace(reason.Text)) Line($"Reason: {reason.Text}");
            if (showDate.IsChecked == true) Line($"Date: {DateTimeOffset.Now:yyyy.MM.dd HH:mm:ss zzz}");
            BitmapSource? img = null;
            if (image.SelectedIndex > 0)
            {
                try
                {
                    img = saved[image.SelectedIndex - 1].Load();
                }
                catch (Exception ex) when (ex is IOException or NotSupportedException)
                {
                    Log.Write($"Loading a saved signature failed: {ex.Message}");
                }
            }
            previewImage.Source = img;
            previewImage.MaxWidth = 160;
            preview.Opacity = visible.IsChecked == true ? 1 : 0.35;
        }
        foreach (var cb in new[] { visible, showDate, showReason, showDn }) cb.Click += (_, _) => UpdatePreview();
        image.SelectionChanged += (_, _) => UpdatePreview();
        reason.AddHandler(System.Windows.Controls.Primitives.TextBoxBase.TextChangedEvent, new TextChangedEventHandler((_, _) => UpdatePreview()));

        var timestamp = dlg.AddCheck("Add a trusted timestamp", s.SignTimestamp);
        var tsaUrl = dlg.AddText("Timestamp server", ChosenTimestampUrl(s));
        dlg.AddNote("Sectigo's free server is suggested; you can enter another that starts with https://. It is contacted only if you add a timestamp, and receives only a hash of the signature, never the document.");
        var longTerm = dlg.AddChoice("Long-term validation", ["None", "Store revocation data (PAdES B-LT)", "Store revocation data, add a document timestamp (PAdES B-LTA)"],
            Pro.Allows(ProFeature.LongTermValidation) ? Math.Clamp(s.SignLongTerm, 0, 2) : 0);
        if (Pro.Allows(ProFeature.LongTermValidation))
            dlg.AddNote("Keeps the signature checkable after your certificate expires. You see which addresses are asked before anything goes online.");
        else
        {
            longTerm.IsEnabled = false;
            dlg.AddNote(Pro.Locked(ProFeature.LongTermValidation));
            var about = dlg.AddFooterButton("About Inkvolt Pro…");
            about.Click += (_, _) => ProWindow.Open(dlg, ProFeature.LongTermValidation);
        }
        void SyncTsa()
        {
            if (longTerm.SelectedIndex > 0) timestamp.IsChecked = true; // both levels rest on it
            timestamp.IsEnabled = longTerm.SelectedIndex == 0;
            tsaUrl.IsEnabled = timestamp.IsChecked == true;
        }
        timestamp.Click += (_, _) => SyncTsa();
        longTerm.SelectionChanged += (_, _) => SyncTsa();
        SyncTsa();

        var certify = dlg.AddChoice("Certify", ["Don't certify (approval signature)", "Certify: no changes allowed", "Certify: form filling allowed",
            "Certify: form filling and comments allowed"]);
        if (alreadySigned)
        {
            certify.IsEnabled = false;
            certify.ToolTip = "Only the first signature can certify a document.";
        }
        refresh = UpdatePreview;
        DescribeId();
        UpdatePreview();

        dlg.Validate(() =>
        {
            if ((ids.SelectedItem as IdItem)?.Cert is null) return "Choose a digital ID.";
            if (timestamp.IsChecked != true) return null;
            if (tsaUrl.Text.Trim().Length == 0) return "Enter the timestamp server's address (https://…), or untick the timestamp.";
            return LtvClient.WhyRefused(tsaUrl.Text.Trim(), LtvAddressKind.Timestamp) is { } why ? $"That timestamp server can't be used: {why}." : null;
        });
        var ok = dlg.ShowModal();
        var chosen = (ids.SelectedItem as IdItem)?.Cert;
        foreach (var i in items)
            if (!ok || !ReferenceEquals(i.Cert, chosen)) i.Cert?.Dispose();
        if (!ok || chosen is null) return null;

        s.SignThumbprint = chosen.Thumbprint;
        s.SignReason = reason.Text.Trim();
        s.SignLocation = location.Text.Trim();
        if (fieldName is null) s.SignVisible = visible.IsChecked == true;
        s.SignShowDate = showDate.IsChecked == true;
        s.SignShowReason = showReason.IsChecked == true;
        s.SignShowDn = showDn.IsChecked == true;
        s.SignImage = image.SelectedIndex > 0 ? saved[image.SelectedIndex - 1].Path : "";
        s.SignTimestamp = timestamp.IsChecked == true;
        s.TimestampUrl = tsaUrl.Text.Trim();
        if (Pro.Allows(ProFeature.LongTermValidation)) s.SignLongTerm = longTerm.SelectedIndex;
        s.Save();

        StampImage? stampImage = null;
        if (image.SelectedIndex > 0)
        {
            try
            {
                stampImage = SignatureImages.ToStampImage(saved[image.SelectedIndex - 1].Load());
            }
            catch (Exception ex) when (ex is IOException or NotSupportedException)
            {
                Log.Write($"Loading a saved signature failed: {ex.Message}");
            }
        }
        var look = new SignatureLook { ShowDate = s.SignShowDate, ShowReason = s.SignShowReason, ShowDistinguishedName = s.SignShowDn, Image = stampImage };
        return new SignChoice(chosen, Empty(s.SignReason), Empty(s.SignLocation), visible.IsChecked == true, look, s.SignTimestamp, s.TimestampUrl,
            (CertificationLevel)certify.SelectedIndex, (LongTermLevel)longTerm.SelectedIndex);

        static string? Empty(string v) => v.Length == 0 ? null : v;
    }

    /// <summary>The timestamp server the person entered. The address that came filled in before there was no default is in many settings files: it doesn't count as chosen.</summary>
    internal static string ChosenTimestampUrl(AppSettings s) =>
        s.TimestampUrl is "" or "http://timestamp.digicert.com" ? LtvPlan.SuggestedTimestampServer : s.TimestampUrl;

    private static X509Certificate2? LoadPfx(Window owner)
    {
        var open = new OpenFileDialog { Title = "Digital ID file", Filter = "Digital ID files (*.pfx;*.p12)|*.pfx;*.p12" };
        if (open.ShowDialog(owner) != true) return null;
        byte[] bytes;
        try
        {
            bytes = File.ReadAllBytes(open.FileName);
        }
        catch (Exception ex) when (ex is IOException or UnauthorizedAccessException)
        {
            Prompt.Error(owner, "The file can't be read", ex.Message);
            return null;
        }
        while (true)
        {
            var dlg = new FormDialog(owner, "Digital ID password", "OK", 400);
            dlg.AddNote(Path.GetFileName(open.FileName));
            var pw = dlg.Add("Password", new PasswordBox());
            dlg.Loaded += (_, _) => pw.Focus();
            if (!dlg.ShowModal()) return null;
            try
            {
                var cert = DigitalIds.LoadPfx(bytes, pw.Password);
                if (DigitalIds.IsUsable(cert)) return cert;
                cert.Dispose();
                Prompt.Error(owner, "This digital ID can't sign", "It is expired, not yet valid, or not meant for signatures.");
                return null;
            }
            catch (SigningException ex) when (ex.Message.Contains("password", StringComparison.OrdinalIgnoreCase))
            {
                Prompt.Error(owner, "Incorrect password", ex.Message);
            }
            catch (SigningException ex)
            {
                Prompt.Error(owner, "This digital ID can't be used", ex.Message);
                return null;
            }
        }
    }

    private static X509Certificate2? CreatePersonal(Window owner)
    {
        var dlg = new FormDialog(owner, "Create a personal digital ID", "Create", 460);
        dlg.AddNote("A self-signed ID: signatures made with it verify, but other people's PDF readers won't trust it until they trust your certificate. It is stored in your Windows certificate store (Current User), valid for 5 years.");
        var name = dlg.AddText("Name", DocumentTab.Author);
        var email = dlg.AddText("Email (optional)");
        var org = dlg.AddText("Organization (optional)");
        var backup = dlg.AddCheck("Also save a backup copy (.pfx) protected by a password");
        var pw1 = dlg.Add("Backup password", new PasswordBox());
        var pw2 = dlg.Add("Confirm password", new PasswordBox());
        void Sync() => pw1.IsEnabled = pw2.IsEnabled = backup.IsChecked == true;
        backup.Click += (_, _) => Sync();
        Sync();
        dlg.AddNote("Without a backup the private key can't be exported: if Windows is reinstalled, the ID is gone.");
        dlg.Validate(() =>
        {
            if (string.IsNullOrWhiteSpace(name.Text)) return "Enter your name.";
            if (backup.IsChecked == true && pw1.Password.Length < 10) return "Use a backup password of at least 10 characters.";
            if (backup.IsChecked == true && pw1.Password != pw2.Password) return "The passwords don't match.";
            return null;
        });
        if (!dlg.ShowModal()) return null;
        var password = backup.IsChecked == true ? pw1.Password : Convert.ToHexString(RandomNumberGenerator.GetBytes(16));
        try
        {
            var pfx = DigitalIds.CreatePersonalPfx(name.Text, email.Text, org.Text, password);
            if (backup.IsChecked == true)
            {
                var save = new SaveFileDialog { Title = "Save the digital ID backup", FileName = $"{name.Text.Trim()} digital ID.pfx", Filter = "Digital ID files (*.pfx)|*.pfx", DefaultExt = ".pfx" };
                if (save.ShowDialog(owner) == true) File.WriteAllBytes(save.FileName, pfx);
            }
            return DigitalIds.Install(pfx, password);
        }
        catch (Exception ex) when (ex is CryptographicException or SigningException or IOException or UnauthorizedAccessException)
        {
            Log.Write($"Creating a digital ID failed: {ex}");
            Prompt.Error(owner, "The digital ID couldn't be created", ex.Message);
            return null;
        }
    }
}
