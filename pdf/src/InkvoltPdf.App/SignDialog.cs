using System.IO;
using System.Security.Cryptography;
using System.Security.Cryptography.X509Certificates;
using System.Windows;
using System.Windows.Automation;
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
    LongTermLevel LongTerm = LongTermLevel.None,
    FieldLock? Lock = null);

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

    private static string[] Reasons =>
    [
        Strings.Sign_ReasonAuthor,
        Strings.Sign_ReasonApprove,
        Strings.Sign_ReasonReviewed,
        Strings.Sign_ReasonAgree,
    ];

    /// <param name="fieldAspect">Width/height of the box the signature goes in (an existing field's), for the preview.</param>
    /// <param name="lockable">The form fields a certifying signature can lock (none: no choice of fields is offered).</param>
    public static SignChoice? Show(Window owner, string? fieldName, double fieldAspect, bool fieldVisible, bool alreadySigned, IReadOnlyList<string> lockable)
    {
        var s = AppSettings.Current;
        var dlg = new FormDialog(owner, fieldName is null ? Strings.Sign_Digitally : Loc.Format(Strings.Sign_Field, fieldName), Strings.Sign_SignButton, 520);
        var items = new System.Collections.ObjectModel.ObservableCollection<IdItem>();
        try
        {
            foreach (var c in DigitalIds.ListUsable()) items.Add(new IdItem(DigitalIds.Describe(c), c));
        }
        catch (CryptographicException ex)
        {
            Log.Write($"Listing digital IDs failed: {ex.Message}");
        }
        items.Add(new IdItem(Strings.Sign_UsePfx, action: () => LoadPfx(dlg)));
        items.Add(new IdItem(Strings.Sign_CreatePersonal, action: () => CreatePersonal(dlg)));

        var ids = new ComboBox { ItemsSource = items };
        var last = items.ToList().FindIndex(i => i.Cert?.Thumbprint == s.SignThumbprint);
        ids.SelectedIndex = last >= 0 ? last : items[0].Cert is not null ? 0 : -1;
        var prev = ids.SelectedIndex;
        dlg.Add(Strings.Sign_DigitalId, ids);
        var idNote = dlg.AddNote("");
        Action refresh = () => { };
        void DescribeId()
        {
            var c = (ids.SelectedItem as IdItem)?.Cert;
            idNote.Text = c is null
                ? Strings.Sign_ChooseIdHint
                : c.Subject + Environment.NewLine + Loc.Format(Strings.Sign_IssuedBy, c.GetNameInfo(X509NameType.SimpleName, true), c.NotAfter);
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

        var reason = dlg.Add(Strings.Sign_Reason, new ComboBox { IsEditable = true, ItemsSource = Reasons, Text = s.SignReason });
        var location = dlg.AddText(Strings.File_PropLocation, s.SignLocation);

        var visible = dlg.AddCheck(Strings.Sign_ShowOnPage, fieldName is null ? s.SignVisible : fieldVisible);
        visible.IsEnabled = fieldName is null;
        var shown = dlg.Add(null, new WrapPanel());
        CheckBox ShowCheck(string text, bool value)
        {
            var box = new CheckBox { Content = text, IsChecked = value, Margin = new Thickness(0, 0, 16, 0) };
            shown.Children.Add(box);
            return box;
        }
        var showDate = ShowCheck(Strings.Sign_ShowDate, s.SignShowDate);
        var showReason = ShowCheck(Strings.Sign_ShowReason, s.SignShowReason);
        var showDn = ShowCheck(Strings.Sign_ShowDn, s.SignShowDn);
        var saved = SignatureLibrary.List().Where(x => !x.Initials).ToList();
        var imageNames = new List<string> { Strings.Sign_NoImage };
        imageNames.AddRange(saved.Select(x => Loc.Format(Strings.Sign_Handwritten, x.Name)));
        var imageIndex = saved.FindIndex(x => x.Path == s.SignImage) + 1;
        var image = dlg.AddChoice(Strings.Sign_ImageBeside, imageNames, imageIndex);

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
        var preview = dlg.Add(Strings.Sign_Preview, new Border { Child = grid, Width = 320, Height = 320 / aspect, HorizontalAlignment = HorizontalAlignment.Left, BorderBrush = Brushes.Gray, BorderThickness = new Thickness(1) });

        void UpdatePreview()
        {
            var c = (ids.SelectedItem as IdItem)?.Cert;
            var name = c?.GetNameInfo(X509NameType.SimpleName, false) ?? Strings.Sign_YourName;
            previewText.Children.Clear();
            void Line(string t) => previewText.Children.Add(new TextBlock { Text = t, Foreground = Brushes.Black, FontFamily = new FontFamily("Arial"), FontSize = 11 });
            Line($"Digitally signed by {name}"); // in every language: the signature's text is written into the PDF in English
            if (showDn.IsChecked == true && c is not null) Line($"DN: {c.Subject}"); // in every language: as written into the PDF
            if (showReason.IsChecked == true && !string.IsNullOrWhiteSpace(reason.Text)) Line($"Reason: {reason.Text}"); // in every language: as written into the PDF
            if (showDate.IsChecked == true) Line($"Date: {DateTimeOffset.Now:yyyy.MM.dd HH:mm:ss zzz}"); // in every language: as written into the PDF
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

        var timestamp = dlg.AddCheck(Strings.Sign_AddTimestamp, s.SignTimestamp);
        var tsaUrl = dlg.AddText(Strings.Ltv_TimestampServer, ChosenTimestampUrl(s));
        dlg.AddNote(Strings.Sign_SectigoNote);
        var longTerm = dlg.AddChoice(Strings.Sign_LongTerm, [Strings.Common_None, Strings.Sign_LtStore, Strings.Sign_LtaStore],
            Pro.Allows(ProFeature.LongTermValidation) ? Math.Clamp(s.SignLongTerm, 0, 2) : 0);
        if (Pro.Allows(ProFeature.LongTermValidation))
            dlg.AddNote(Strings.Sign_LongTermNote);
        else
        {
            longTerm.IsEnabled = false;
            dlg.AddNote(Pro.Locked(ProFeature.LongTermValidation));
            var about = dlg.AddFooterButton(Strings.Batch_AboutPro);
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

        var certify = dlg.AddChoice(Strings.Sign_Certify, [Strings.Sign_CertifyNo, Strings.Sign_CertifyNoChanges, Strings.Sign_CertifyForms,
            Strings.Sign_CertifyFormsComments]);
        if (alreadySigned)
        {
            certify.IsEnabled = false;
            certify.ToolTip = Strings.Sign_FirstCertifies;
        }
        // Certifying a form: which of its fields to lock (FieldMDP). A locked field changed later shows as not allowed.
        ComboBox? lockChoice = null;
        ListBox? lockList = null;
        if (lockable.Count > 0 && !alreadySigned)
        {
            lockChoice = dlg.AddChoice(Strings.Sign_LockFields, FieldLocks.Choices);
            lockList = dlg.Add(null, new ListBox { MaxHeight = 132, SelectionMode = SelectionMode.Multiple, ItemsSource = lockable,
                ToolTip = Strings.Sign_LockTip, Visibility = Visibility.Collapsed }, top: 6);
            AutomationProperties.SetName(lockList, Strings.Sign_FormFields);
            var lockNote = dlg.AddNote("");
            if (!Pro.Allows(ProFeature.FieldLocking))
            {
                lockChoice.IsEnabled = false;
                lockNote.Text = Pro.Locked(ProFeature.FieldLocking);
            }
            void SyncLock()
            {
                var certifying = certify.SelectedIndex > 0;
                lockChoice.IsEnabled = certifying && Pro.Allows(ProFeature.FieldLocking);
                var picks = certifying && lockChoice.SelectedIndex is 2 or 3;
                lockList.Visibility = picks ? Visibility.Visible : Visibility.Collapsed;
                if (Pro.Allows(ProFeature.FieldLocking))
                    lockNote.Text = certifying ? FieldLocks.Note(lockChoice.SelectedIndex) : Strings.Sign_CertifyToLock;
            }
            certify.SelectionChanged += (_, _) => SyncLock();
            lockChoice.SelectionChanged += (_, _) => SyncLock();
            SyncLock();
        }
        refresh = UpdatePreview;
        DescribeId();
        UpdatePreview();

        dlg.Validate(() =>
        {
            if ((ids.SelectedItem as IdItem)?.Cert is null) return Strings.Sign_ChooseId;
            if (lockChoice is { IsEnabled: true, SelectedIndex: 2 or 3 } && lockList!.SelectedItems.Count == 0)
                return lockChoice.SelectedIndex == 2 ? Strings.Sign_ChooseToLock : Strings.Sign_ChooseToLeave;
            if (timestamp.IsChecked != true) return null;
            if (tsaUrl.Text.Trim().Length == 0) return Strings.Sign_EnterServer;
            return LtvClient.WhyRefused(tsaUrl.Text.Trim(), LtvAddressKind.Timestamp) is { } why ? Loc.Format(Strings.Ltv_ServerRefused, why) : null;
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
            (CertificationLevel)certify.SelectedIndex, (LongTermLevel)longTerm.SelectedIndex,
            lockChoice is { IsEnabled: true } && certify.SelectedIndex > 0
                ? FieldLocks.From(lockChoice.SelectedIndex, lockList!.SelectedItems.Cast<string>().ToList()) : null);

        static string? Empty(string v) => v.Length == 0 ? null : v;
    }

    /// <summary>The timestamp server the person entered. The address that came filled in before there was no default is in many settings files: it doesn't count as chosen.</summary>
    internal static string ChosenTimestampUrl(AppSettings s) =>
        s.TimestampUrl is "" or "http://timestamp.digicert.com" ? LtvPlan.SuggestedTimestampServer : s.TimestampUrl;

    private static X509Certificate2? LoadPfx(Window owner)
    {
        var open = new OpenFileDialog { Title = Strings.Sign_IdFile, Filter = Strings.Sign_IdFilter };
        if (open.ShowDialog(owner) != true) return null;
        byte[] bytes;
        try
        {
            bytes = File.ReadAllBytes(open.FileName);
        }
        catch (Exception ex) when (ex is IOException or UnauthorizedAccessException)
        {
            Prompt.Error(owner, Strings.Sign_CantRead, ex.Message);
            return null;
        }
        while (true)
        {
            var dlg = new FormDialog(owner, Strings.Sign_IdPassword, Strings.Common_OK, 400);
            dlg.AddNote(Path.GetFileName(open.FileName));
            var pw = dlg.Add(Strings.PdfA_Password, new PasswordBox());
            dlg.Loaded += (_, _) => pw.Focus();
            if (!dlg.ShowModal()) return null;
            try
            {
                var cert = DigitalIds.LoadPfx(bytes, pw.Password);
                if (DigitalIds.IsUsable(cert)) return cert;
                cert.Dispose();
                Prompt.Error(owner, Strings.Sign_CantSign, Strings.Sign_CantSignBody);
                return null;
            }
            catch (SigningException ex) when (ex.Message.Contains("password", StringComparison.OrdinalIgnoreCase))
            {
                Prompt.Error(owner, Strings.Sign_WrongPassword, ex.Message);
            }
            catch (SigningException ex)
            {
                Prompt.Error(owner, Strings.Sign_CantUse, ex.Message);
                return null;
            }
        }
    }

    private static X509Certificate2? CreatePersonal(Window owner)
    {
        var dlg = new FormDialog(owner, Strings.Sign_CreateTitle, Strings.File_Create, 460);
        dlg.AddNote(Strings.Sign_CreateNote);
        var name = dlg.AddText(Strings.Sign_Name, DocumentTab.Author);
        var email = dlg.AddText(Strings.Sign_Email);
        var org = dlg.AddText(Strings.Sign_Organization);
        var backup = dlg.AddCheck(Strings.Sign_Backup);
        var pw1 = dlg.Add(Strings.Sign_BackupPassword, new PasswordBox());
        var pw2 = dlg.Add(Strings.Sign_ConfirmPassword, new PasswordBox());
        void Sync() => pw1.IsEnabled = pw2.IsEnabled = backup.IsChecked == true;
        backup.Click += (_, _) => Sync();
        Sync();
        dlg.AddNote(Strings.Sign_NoBackupNote);
        dlg.Validate(() =>
        {
            if (string.IsNullOrWhiteSpace(name.Text)) return Strings.Sign_EnterName;
            if (backup.IsChecked == true && pw1.Password.Length < 10) return Strings.Sign_BackupTooShort;
            if (backup.IsChecked == true && pw1.Password != pw2.Password) return Strings.Sign_PasswordsMismatch;
            return null;
        });
        if (!dlg.ShowModal()) return null;
        var password = backup.IsChecked == true ? pw1.Password : Convert.ToHexString(RandomNumberGenerator.GetBytes(16));
        try
        {
            var pfx = DigitalIds.CreatePersonalPfx(name.Text, email.Text, org.Text, password);
            if (backup.IsChecked == true)
            {
                var save = new SaveFileDialog { Title = Strings.Sign_SaveBackup, FileName = Loc.Format(Strings.Sign_BackupFileName, name.Text.Trim()), Filter = Strings.Sign_PfxFilter, DefaultExt = ".pfx" };
                if (save.ShowDialog(owner) == true) File.WriteAllBytes(save.FileName, pfx);
            }
            return DigitalIds.Install(pfx, password);
        }
        catch (Exception ex) when (ex is CryptographicException or SigningException or IOException or UnauthorizedAccessException)
        {
            Log.Write($"Creating a digital ID failed: {ex}");
            Prompt.Error(owner, Strings.Sign_CouldntCreate, ex.Message);
            return null;
        }
    }
}
