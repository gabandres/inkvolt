using System.Windows;
using System.Windows.Controls;
using System.Windows.Controls.Primitives;
using System.Windows.Media;
using InkvoltPdf.Core;

namespace InkvoltPdf.App;

/// <summary>File › Protect with Password / Remove Protection, the security line in Properties, and the open-password prompt.</summary>
public static class SecurityActions
{
    /// <summary>The document's protection, or null when it can't be read (not a PDF, damaged).</summary>
    public static SecurityInfo? Read(DocumentSession s)
    {
        if (!s.IsPdf) return null;
        try
        {
            return PdfSecurity.ReadSecurity(s.Data, s.Password ?? s.OpenPassword);
        }
        catch (Exception ex) when (ex is PasswordRequiredException or InvalidOperationException or PdfSharp.PdfSharpException)
        {
            Log.Write($"Security unreadable: {ex.Message}");
            return null;
        }
    }

    /// <summary>One line for Document Properties: "AES-256 · needs a password to open · no copying".</summary>
    public static string? Describe(DocumentSession s)
    {
        if (!s.IsPdf) return s.Engine.IsEncrypted ? Strings.Security_Encrypted : null;
        if (Read(s) is not { } info) return s.Engine.IsEncrypted ? Strings.Security_Encrypted : null;
        if (!info.IsEncrypted) return Strings.Security_NotProtected;
        var parts = new List<string>
        {
            info.Method switch
            {
                EncryptionMethod.Aes256 => "AES-256",
                EncryptionMethod.Aes128 => "AES-128",
                EncryptionMethod.Rc4With128Bits => Strings.Security_Rc4128,
                EncryptionMethod.Rc4With40Bits => Strings.Security_Rc440,
                _ => Strings.Security_Encrypted,
            },
            info.RequiresOpenPassword ? Strings.Security_NeedsOpen : Strings.Security_OpensWithout,
        };
        var p = info.Permissions;
        if (p.IsUnrestricted) parts.Add(Strings.Security_NoRestrictions);
        else
        {
            if (p.Print == PrintPermission.None) parts.Add(Strings.Security_NoPrinting);
            else if (p.Print == PrintPermission.LowResolution) parts.Add(Strings.Security_LowResPrinting);
            if (!p.Copy) parts.Add(Strings.Security_NoCopying);
            if (!p.Modify) parts.Add(Strings.Security_NoEditing);
            if (!p.Annotate) parts.Add(Strings.Security_NoComments);
            if (!p.FillForms) parts.Add(Strings.Security_NoFilling);
            if (!p.Assemble) parts.Add(Strings.Security_NoPageChanges);
        }
        return string.Join(" · ", parts);
    }

    public static async Task Protect(Window owner, DocumentTab tab)
    {
        if (!tab.Session.IsPdf || !await tab.SettleAsync()) return;
        var current = Read(tab.Session);
        var encrypted = current?.IsEncrypted == true;
        var choice = AskProtection(owner, encrypted ? Strings.Security_ChangeTitle : Strings.Security_ProtectTitle, Strings.Security_Protect, current,
            encrypted
                ? Strings.Security_ChangeNote
                : Strings.Security_ProtectNote);
        if (choice is null) return;
        var (user, ownerPw, permissions, encryption) = choice;
        // Without a permissions password the open password doubles as one (nothing is restricted then).
        var sessionPassword = ownerPw ?? user;
        if (await tab.RunEdit(encrypted ? Strings.Security_ChangeLabel : Strings.Security_ProtectLabel,
                (d, pw) => PdfSecurity.Protect(d, pw, user, ownerPw, permissions, encryption), quiet: true,
                newPasswords: (sessionPassword, user)))
            tab.ShowNotice(user is not null
                ? Strings.Security_ProtectedSave
                : Strings.Security_RestrictionsSet);
    }

    /// <summary>
    /// The command bar's Protect: the smallest question, a password to open the PDF (typed twice), AES-256, nothing
    /// restricted. A PDF already protected gets the full window (<see cref="Protect"/>), which shows what it has now.
    /// </summary>
    public static async Task ProtectAtOnce(Window owner, DocumentTab tab)
    {
        if (!tab.Session.IsPdf || !await tab.SettleAsync()) return;
        if (Read(tab.Session)?.IsEncrypted == true)
        {
            await Protect(owner, tab);
            return;
        }
        var dlg = new FormDialog(owner, Strings.Security_ProtectTitle, Strings.Security_Protect, 420);
        dlg.AddNote(Loc.Format(Strings.Security_QuickNote, Cmd.ProtectPassword.Text.Replace("_", "", StringComparison.Ordinal)));
        var openBox = new PasswordBox { MaxLength = 127 };
        var openConfirm = new PasswordBox { MaxLength = 127 };
        var meter = new StrengthMeter();
        var panel = Fields((Strings.Security_OpenPassword, openBox), (Strings.Security_Confirm, openConfirm));
        panel.Children.Add(meter);
        dlg.Add(null, panel);
        openBox.PasswordChanged += (_, _) => meter.Show(openBox.Password);
        openBox.Loaded += (_, _) => openBox.Focus();
        dlg.Validate(() => openBox.Password.Length == 0 ? Strings.Security_EnterOpen
            : openBox.Password != openConfirm.Password ? Strings.Security_OpenMismatch : null);
        if (!dlg.ShowModal()) return;
        var user = openBox.Password;
        if (await tab.RunEdit(Strings.Security_ProtectLabel,
                (d, pw) => PdfSecurity.Protect(d, pw, user, null, PdfPermissions.All, EncryptionMethod.Aes256), quiet: true,
                newPasswords: (user, user)))
            tab.ShowNotice(Strings.Security_ProtectedSave);
    }

    /// <summary>Passwords and permissions chosen in <see cref="AskProtection"/> (null passwords: not set).</summary>
    internal sealed record ProtectionChoice(string? UserPassword, string? OwnerPassword, PdfPermissions Permissions, EncryptionMethod Method)
    {
        public override string ToString() => "Protection"; // never the passwords
    }

    /// <summary>The Protect with Password dialog (also File › Batch): open password, restrictions, encryption. Null when cancelled.</summary>
    internal static ProtectionChoice? AskProtection(Window owner, string title, string okText, SecurityInfo? current, string note)
    {
        var perms = current?.IsEncrypted == true ? current.Permissions : PdfPermissions.All;
        var dlg = new FormDialog(owner, title, okText, 500);
        dlg.AddNote(note);

        // Open (user) password
        var needOpen = dlg.Add(Strings.Security_Opening, new CheckBox { Content = Strings.Security_RequireOpen, IsChecked = current?.RequiresOpenPassword == true });
        var openBox = new PasswordBox { MaxLength = 127 };
        var openConfirm = new PasswordBox { MaxLength = 127 };
        var meter = new StrengthMeter();
        var openPanel = Fields((Strings.Security_OpenPassword, openBox), (Strings.Security_Confirm, openConfirm));
        openPanel.Children.Add(meter);
        dlg.Add(null, openPanel);
        openBox.PasswordChanged += (_, _) => meter.Show(openBox.Password);

        // Permissions (owner) password and what it restricts
        var restrict = dlg.Add(Strings.Security_Permissions, new CheckBox { Content = Strings.Security_Restrict, IsChecked = !perms.IsUnrestricted });
        var ownerBox = new PasswordBox { MaxLength = 127 };
        var ownerConfirm = new PasswordBox { MaxLength = 127 };
        var permPanel = Fields((Strings.Security_PermissionsPassword, ownerBox), (Strings.Security_Confirm, ownerConfirm));
        var print = new ComboBox
        {
            ItemsSource = new[] { Strings.Security_HighRes, Strings.Security_LowRes, Strings.Security_NotAllowed },
            SelectedIndex = perms.Print switch { PrintPermission.HighResolution => 0, PrintPermission.LowResolution => 1, _ => 2 },
            Margin = new Thickness(0, 4, 0, 6),
            HorizontalAlignment = HorizontalAlignment.Left,
            MinWidth = 220,
        };
        permPanel.Children.Add(new TextBlock { Text = Strings.Security_Printing, Margin = new Thickness(0, 8, 0, 2) });
        permPanel.Children.Add(print);
        CheckBox Allow(string text, bool on)
        {
            var c = new CheckBox { Content = text, IsChecked = on, Margin = new Thickness(0, 2, 0, 2) };
            permPanel.Children.Add(c);
            return c;
        }
        var copy = Allow(Strings.Security_AllowCopy, perms.Copy);
        var edit = Allow(Strings.Security_AllowEdit, perms.Modify);
        var comment = Allow(Strings.Security_AllowComment, perms.Annotate);
        var fill = Allow(Strings.Security_AllowFill, perms.FillForms);
        var assemble = Allow(Strings.Security_AllowAssemble, perms.Assemble);
        dlg.Add(null, permPanel);

        var method = dlg.AddChoice(Strings.Security_Encryption,
            [Strings.Security_Aes256, Strings.Security_Aes128],
            current?.Method == EncryptionMethod.Aes128 ? 1 : 0);

        void Sync()
        {
            openPanel.Visibility = needOpen.IsChecked == true ? Visibility.Visible : Visibility.Collapsed;
            permPanel.Visibility = restrict.IsChecked == true ? Visibility.Visible : Visibility.Collapsed;
        }
        needOpen.Click += (_, _) => Sync();
        restrict.Click += (_, _) => Sync();
        Sync();

        dlg.Validate(() =>
        {
            var wantOpen = needOpen.IsChecked == true;
            var wantRestrict = restrict.IsChecked == true;
            if (!wantOpen && !wantRestrict) return Strings.Security_ChooseSomething;
            if (wantOpen)
            {
                if (openBox.Password.Length == 0) return Strings.Security_EnterOpen;
                if (openBox.Password != openConfirm.Password) return Strings.Security_OpenMismatch;
            }
            if (wantRestrict)
            {
                if (ownerBox.Password.Length == 0) return Strings.Security_EnterPerms;
                if (ownerBox.Password != ownerConfirm.Password) return Strings.Security_PermsMismatch;
                if (wantOpen && ownerBox.Password == openBox.Password) return Strings.Security_PermsSame;
            }
            return null;
        });
        if (!dlg.ShowModal()) return null;

        var user = needOpen.IsChecked == true ? openBox.Password : null;
        var ownerPw = restrict.IsChecked == true ? ownerBox.Password : null;
        var permissions = restrict.IsChecked == true
            ? new PdfPermissions(
                print.SelectedIndex switch { 0 => PrintPermission.HighResolution, 1 => PrintPermission.LowResolution, _ => PrintPermission.None },
                copy.IsChecked == true, edit.IsChecked == true, comment.IsChecked == true, fill.IsChecked == true, assemble.IsChecked == true)
            : PdfPermissions.All;
        var encryption = method.SelectedIndex == 1 ? EncryptionMethod.Aes128 : EncryptionMethod.Aes256;
        return new ProtectionChoice(user, ownerPw, permissions, encryption);
    }

    public static async Task RemoveProtection(Window owner, DocumentTab tab)
    {
        if (!tab.Session.IsPdf || !await tab.SettleAsync()) return;
        if (!Prompt.Confirm(owner, Strings.Security_RemoveTitle,
                Strings.Security_RemoveBody, Strings.Security_RemoveButton, warning: true)) return;
        await tab.RunEdit(Strings.Security_RemoveLabel, (d, pw) => PdfSecurity.Unprotect(d, pw), newPasswords: (null, null));
    }

    /// <summary>
    /// Asks for the open password an edit of an AES-256 document opened with its owner password needs (checked against
    /// the file), or lets the user save without one. Null when cancelled.
    /// </summary>
    public static OpenPasswordAnswer? PromptOpenPassword(Window? owner, string name, byte[] data)
    {
        var dlg = new FormDialog(owner!, Strings.Security_KeepOpenTitle, Strings.Security_KeepIt, 480);
        dlg.AddNote(Loc.Format(Strings.Security_KeepOpenNote, name));
        var box = dlg.Add(Strings.Security_OpenPassword, new PasswordBox());
        OpenPasswordAnswer? answer = null;
        var drop = dlg.Add(null, new Button
        {
            Content = Strings.Security_SaveWithoutOpen,
            Style = (Style)Application.Current.FindResource("TextButton"),
            HorizontalAlignment = HorizontalAlignment.Left,
            ToolTip = Strings.Security_SaveWithoutOpenTip,
        });
        drop.Click += (_, _) =>
        {
            answer = new OpenPasswordAnswer(null, true);
            dlg.DialogResult = true;
        };
        dlg.Loaded += (_, _) => box.Focus();
        dlg.Validate(() => box.Password.Length == 0 ? Strings.Security_EnterOpen
            : PdfSecurity.IsOpenPassword(data, box.Password) ? null : Strings.Security_NotOpenPassword);
        if (!dlg.ShowModal()) return null;
        return answer ?? new OpenPasswordAnswer(box.Password, false);
    }

    /// <summary>Labeled password rows in a panel that can be enabled as a whole.</summary>
    private static StackPanel Fields(params (string Label, Control Box)[] rows)
    {
        var panel = new StackPanel { Margin = new Thickness(24, 4, 0, 0) };
        foreach (var (label, box) in rows)
        {
            panel.Children.Add(new TextBlock { Text = label, Margin = new Thickness(0, 6, 0, 2) });
            System.Windows.Automation.AutomationProperties.SetName(box, label);
            panel.Children.Add(box);
        }
        return panel;
    }

    /// <summary>Four segments and a word: how strong the typed password looks.</summary>
    private sealed class StrengthMeter : DockPanel
    {
        private readonly Border[] _bars = new Border[4];
        private readonly TextBlock _label = new() { Margin = new Thickness(10, 0, 0, 0), MinWidth = 50, FontSize = 12 };

        public StrengthMeter()
        {
            Margin = new Thickness(0, 8, 0, 0);
            SetDock(_label, Dock.Right);
            Children.Add(_label);
            var bars = new UniformGrid { Columns = 4, Height = 4, VerticalAlignment = VerticalAlignment.Center };
            for (var i = 0; i < 4; i++)
            {
                _bars[i] = new Border { CornerRadius = new CornerRadius(2), Margin = new Thickness(0, 0, 4, 0) };
                bars.Children.Add(_bars[i]);
            }
            Children.Add(bars);
            _label.SetResourceReference(TextBlock.ForegroundProperty, "TextFillColorSecondaryBrush");
            Show("");
        }

        public void Show(string password)
        {
            var (score, label) = PasswordStrength.Rate(password);
            _label.Text = label;
            var key = score switch { 1 => "SystemFillColorCriticalBrush", 2 => "SystemFillColorCautionBrush", _ => "SystemFillColorSuccessBrush" };
            for (var i = 0; i < 4; i++)
                _bars[i].SetResourceReference(Border.BackgroundProperty, i < score ? key : "ControlStrongFillColorDisabledBrush");
            System.Windows.Automation.AutomationProperties.SetName(this, label.Length == 0 ? Strings.Security_Strength : Loc.Format(Strings.Security_StrengthIs, label));
        }
    }
}
