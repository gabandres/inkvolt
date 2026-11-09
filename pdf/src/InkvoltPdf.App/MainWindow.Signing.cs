using System.IO;
using System.Windows;
using System.Windows.Controls;
using System.Windows.Controls.Primitives;
using InkvoltPdf.App.Viewer;
using InkvoltPdf.Core;

namespace InkvoltPdf.App;

/// <summary>Sign Digitally (dialog → box → sign → Save As) and the Sign menu of saved handwritten signatures.</summary>
public partial class MainWindow
{
    private bool _signing;

    /// <summary>The dev script's way to a local authority: a client that may reach this PC's loopback. Null always outside a script.</summary>
    internal Func<LtvClient>? DevLtvClient { get; set; }

    internal LtvClient NewLtvClient() => DevLtvClient?.Invoke() ?? new LtvClient();

    /// <summary>
    /// Signs the active document: commits open editors and waits for pending writes, asks for the digital ID and options,
    /// lets the user drag the box (visible, new field), signs as an incremental update, then saves the signed copy
    /// (default "&lt;name&gt;-signed.pdf"); the tab then shows the signed file and its verification.
    /// </summary>
    internal async Task SignDigitallyAsync(DocumentTab t, string? field, SignChoice? scripted = null, SignaturePlacement? scriptedBox = null)
    {
        if (_signing) return;
        _signing = true;
        try
        {
            await t.FlushPendingEditsAsync();
            if (t.IsDisposed) return;
            if (t.Session.HasEncryption) // also a PDF that only restricts printing or copying: signing can't keep its encryption
            {
                Prompt.Info(this, Strings.Main_SignProtectedTitle,
                    Strings.Main_SignProtectedBody);
                return;
            }
            var (aspect, fieldVisible) = field is null ? (3.6, true) : t.SignatureFieldShape(field);
            var choice = scripted ?? SignDialog.Show(this, field, aspect, fieldVisible, t.IsSigned, t.LockableFields);
            if (choice is null) return;
            using var cert = choice.Certificate;
            using var client = NewLtvClient();
            if (choice.LongTerm != LongTermLevel.None)
            {
                // Before anything else happens: what is contacted, in the person's own view of it.
                var plan = await Task.Run(() => Ltv.Plan(cert, choice.TimestampUrl, client));
                if (!LtvDialogs.ConfirmSign(this, plan, choice.LongTerm))
                {
                    ShowStatus(Strings.Main_SigningCancelled);
                    return;
                }
            }

            SignaturePlacement? box = null;
            if (field is null && choice.Visible)
            {
                box = scriptedBox ?? await t.PickSignatureBoxAsync();
                if (box is null || t.IsDisposed)
                {
                    ShowStatus(Strings.Main_SigningCancelled);
                    return;
                }
            }
            ShowStatus(choice.LongTerm != LongTermLevel.None ? Strings.Main_SigningLongTerm : choice.Timestamp ? Strings.Main_SigningTimestamp : Strings.Main_Signing);
            var request = new SignRequest
            {
                Certificate = cert,
                RepairedLength = t.Session.RepairedLength,
                FieldName = field,
                PageIndex = box?.PageIndex ?? 0,
                Rect = box?.Rect,
                Reason = choice.Reason,
                Location = choice.Location,
                Look = choice.Look,
                Timestamp = choice.Timestamp ? client.TimestampSender(choice.TimestampUrl) : null,
                Certify = choice.Certify,
                Lock = choice.Lock,
                LongTerm = choice.LongTerm,
                LongTermClient = choice.LongTerm != LongTermLevel.None ? client : null,
            };
            var outcome = await t.ApplySignatureAsync(request);
            if (outcome == EditOutcome.Declined) ShowStatus(Strings.Main_SigningCancelled); // e.g. the PIN prompt was cancelled
            if (outcome != EditOutcome.Done || t.IsDisposed) return;

            // The signature must be the file's last change: save the signed bytes as they are.
            var name = Path.GetFileNameWithoutExtension(t.Session.DisplayName);
            if (!await SaveAsDialogAsync(t, name.EndsWith("-signed", StringComparison.OrdinalIgnoreCase) ? name + ".pdf" : name + "-signed.pdf"))
            {
                if (!t.IsDisposed && t.Session.UndoLabel == Strings.TabSign_EditSign) t.Undo();
                ShowStatus(Strings.Main_NotSigned);
                return;
            }
            t.ShowSignatureDetails(field);
        }
        finally
        {
            _signing = false;
            System.Windows.Input.CommandManager.InvalidateRequerySuggested();
        }
    }

    /// <summary>
    /// Add Verification Information: shows what would be contacted, asks, stores the answers as an update after the
    /// signatures, then saves the copy (default "&lt;name&gt;-ltv.pdf"), as signing does. Whatever fails, nothing is written.
    /// </summary>
    internal async Task AddVerificationAsync(DocumentTab t)
    {
        if (_signing) return;
        _signing = true;
        try
        {
            await t.FlushPendingEditsAsync();
            if (t.IsDisposed || !ProGate.Check(this, ProFeature.LongTermValidation)) return;
            if (t.Session.HasEncryption)
            {
                Prompt.Info(this, Strings.Main_LtvProtectedTitle,
                    Strings.Main_LtvProtectedBody);
                return;
            }
            var data = t.Session.Data;
            var password = t.Session.Password;
            var repaired = t.Session.RepairedLength;
            using var client = NewLtvClient();
            var plan = await Task.Run(() => Ltv.Plan(data, password, client, repairedLength: repaired));
            if (t.IsDisposed) return;
            var url = LtvDialogs.ConfirmAdd(this, plan, client);
            if (url is null) return;
            ShowStatus(Strings.Main_GettingLongTerm);
            var (outcome, result) = await t.AddVerificationAsync(client, url.Length == 0 ? null : url);
            if (outcome != EditOutcome.Done || result is null || t.IsDisposed) return;
            if (!result.Changed)
            {
                // Same bytes back: nothing to keep in the undo list or to save.
                if (t.Session.UndoLabel == Strings.TabSign_EditAddVerification) t.Undo();
                t.ShowLongTermOutcome(Strings.Main_LtvNothingToAdd, LtvDialogs.Describe(result.Certificates, result.Contacts));
                return;
            }
            // The data must be the file's last change for the signatures to read as they do: save the bytes as they are.
            var name = Path.GetFileNameWithoutExtension(t.Session.DisplayName);
            if (!await SaveAsDialogAsync(t, name.EndsWith("-ltv", StringComparison.OrdinalIgnoreCase) ? name + ".pdf" : name + "-ltv.pdf"))
            {
                if (!t.IsDisposed && t.Session.UndoLabel == Strings.TabSign_EditAddVerification) t.Undo();
                ShowStatus(Strings.Main_LtvNotAdded);
                return;
            }
            var gaps = result.Certificates.Count(c => !c.Covered);
            t.ShowLongTermOutcome(gaps == 0 ? Strings.Main_LtvAdded : Loc.Plural(gaps, Strings.Main_LtvAddedGaps_One, Strings.Main_LtvAddedGaps_Many),
                LtvDialogs.Describe(result.Certificates, result.Contacts));
        }
        finally
        {
            _signing = false;
            System.Windows.Input.CommandManager.InvalidateRequerySuggested();
        }
    }

    /// <summary>Check Signatures Online: shows what would be contacted, asks, and shows the signatures in that light. The file stays as it is.</summary>
    internal async Task CheckSignaturesOnlineAsync(DocumentTab t)
    {
        if (_signing) return;
        _signing = true;
        try
        {
            await t.FlushPendingEditsAsync();
            if (t.IsDisposed) return;
            var data = t.Session.Data;
            var password = t.Session.Password;
            var repaired = t.Session.RepairedLength;
            using var client = NewLtvClient();
            var plan = await Task.Run(() => Ltv.Plan(data, password, client, onlyMissing: false, repairedLength: repaired));
            if (t.IsDisposed || !LtvDialogs.ConfirmOnline(this, plan)) return;
            ShowStatus(Strings.Main_CheckingSignaturesOnline);
            LtvOnlineResult result;
            using (t.BeginBusy(Strings.Main_CheckingSignaturesOnline))
                result = await Task.Run(() => Ltv.CheckOnlineAsync(data, password, client, repairedLength: repaired));
            if (!t.IsDisposed) t.ShowOnlineCheck(result);
        }
        catch (Exception ex) when (ex is SigningException or LtvFetchException)
        {
            Prompt.Error(this, Strings.Main_CheckFailed, ex.Message);
        }
        finally
        {
            _signing = false;
            System.Windows.Input.CommandManager.InvalidateRequerySuggested();
        }
    }

    /// <summary>The Sign menu: saved signatures and initials to place, add/delete them, Sign Digitally.</summary>
    private void ShowSignatureMenu(DocumentTab t)
    {
        var menu = new ContextMenu();
        var saved = SignatureLibrary.List();
        foreach (var s in saved)
        {
            var sig = s;
            var header = new StackPanel { Orientation = Orientation.Horizontal };
            try
            {
                header.Children.Add(new Border
                {
                    Background = System.Windows.Media.Brushes.White,
                    Padding = new Thickness(4, 2, 4, 2),
                    Child = new Image { Source = s.Load(), Height = 28, MaxWidth = 140, Stretch = System.Windows.Media.Stretch.Uniform },
                });
            }
            catch (Exception ex) when (ex is IOException or NotSupportedException)
            {
                Log.Write($"Loading a saved signature failed: {ex.Message}");
                continue;
            }
            header.Children.Add(new TextBlock { Text = s.Name, Margin = new Thickness(10, 0, 0, 0), VerticalAlignment = VerticalAlignment.Center });
            var item = new MenuItem { Header = header };
            System.Windows.Automation.AutomationProperties.SetName(item, Loc.Format(Strings.Main_PlaceSignature, s.Name));
            item.Click += (_, _) => t.BeginPlaceSignature(sig);
            menu.Items.Add(item);
        }
        if (menu.Items.Count > 0) menu.Items.Add(new Separator());
        var signatures = saved.Count(s => !s.Initials);
        var add = new MenuItem { Header = Strings.Main_AddSignatureMenu, IsEnabled = signatures < SignatureLibrary.MaxSignatures };
        if (!add.IsEnabled) add.ToolTip = Loc.Format(Strings.Main_SignatureLimit, SignatureLibrary.MaxSignatures);
        add.Click += (_, _) => CaptureSignature(t, initials: false);
        menu.Items.Add(add);
        var initials = new MenuItem { Header = saved.Any(s => s.Initials) ? Strings.Main_ReplaceInitialsMenu : Strings.Main_AddInitialsMenu };
        initials.Click += (_, _) => CaptureSignature(t, initials: true);
        menu.Items.Add(initials);
        if (saved.Count > 0)
        {
            var delete = new MenuItem { Header = Strings.Main_DeleteSignatureMenu };
            foreach (var s in saved)
            {
                var sig = s;
                var d = new MenuItem { Header = s.Name };
                d.Click += (_, _) =>
                {
                    if (!Prompt.Confirm(this, Loc.Format(Strings.Main_DeleteSignatureTitle, sig.Name), Strings.Main_DeleteSignatureBody, Strings.Common_Delete)) return;
                    try
                    {
                        SignatureLibrary.Delete(sig);
                    }
                    catch (Exception ex) when (ex is IOException or UnauthorizedAccessException)
                    {
                        Prompt.Error(this, Strings.Main_DeleteSignatureFailed, ex.Message);
                    }
                };
                delete.Items.Add(d);
            }
            menu.Items.Add(delete);
        }
        menu.Items.Add(new Separator());
        menu.Items.Add(new MenuItem { Command = Cmd.Sign, CommandTarget = this });

        var fillSign = BarGroup("FillSign");
        menu.PlacementTarget = fillSign?.IsVisible == true ? fillSign : this;
        menu.Placement = fillSign?.IsVisible == true ? PlacementMode.Bottom : PlacementMode.Center;
        menu.Closed += (_, _) => UpdateUi();
        menu.IsOpen = true;
        if (fillSign is not null) fillSign.Body.IsChecked = true;
    }

    /// <summary>
    /// Fill &amp; Sign's one click: your signature, ready to place (the first saved one; click the page to put it there).
    /// With none saved yet it asks you to make one, then places it; with only initials, the Sign menu (Shift+click too).
    /// </summary>
    private void SignAtOnce(DocumentTab t)
    {
        var saved = SignatureLibrary.List();
        if (saved.Count > 0 && saved.All(s => s.Initials)) ShowSignatureMenu(t);
        else if (saved.FirstOrDefault(s => !s.Initials) is { } signature) t.BeginPlaceSignature(signature);
        else CaptureSignature(t, initials: false);
    }

    private void CaptureSignature(DocumentTab t, bool initials)
    {
        var dlg = new SignatureCaptureDialog(this, initials, DocumentTab.Author);
        if (dlg.ShowDialog() != true || dlg.Result is null || t.IsDisposed) return;
        SavedSignature? saved;
        try
        {
            saved = SignatureLibrary.Save(dlg.Result, initials);
        }
        catch (Exception ex) when (ex is IOException or UnauthorizedAccessException)
        {
            Prompt.Error(this, Strings.Main_SaveSignatureFailed, ex.Message);
            return;
        }
        if (saved is null)
        {
            Prompt.Info(this, Strings.Main_NoRoomTitle, Loc.Format(Strings.Main_NoRoomBody, SignatureLibrary.MaxSignatures));
            return;
        }
        t.BeginPlaceSignature(saved);
    }
}
