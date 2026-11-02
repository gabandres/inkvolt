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

    private LtvClient NewLtvClient() => DevLtvClient?.Invoke() ?? new LtvClient();

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
                Prompt.Info(this, "Protected PDFs can't be signed",
                    "Remove the protection first (File › Remove Protection), then sign: the signed copy is saved as a new file.");
                return;
            }
            var (aspect, fieldVisible) = field is null ? (3.6, true) : t.SignatureFieldShape(field);
            var choice = scripted ?? SignDialog.Show(this, field, aspect, fieldVisible, t.IsSigned);
            if (choice is null) return;
            using var cert = choice.Certificate;
            using var client = NewLtvClient();
            if (choice.LongTerm != LongTermLevel.None)
            {
                // Before anything else happens: what is contacted, in the person's own view of it.
                var plan = await Task.Run(() => Ltv.Plan(cert, choice.TimestampUrl, client));
                if (!LtvDialogs.ConfirmSign(this, plan, choice.LongTerm))
                {
                    ShowStatus("Signing cancelled");
                    return;
                }
            }

            SignaturePlacement? box = null;
            if (field is null && choice.Visible)
            {
                box = scriptedBox ?? await t.PickSignatureBoxAsync();
                if (box is null || t.IsDisposed)
                {
                    ShowStatus("Signing cancelled");
                    return;
                }
            }
            ShowStatus(choice.LongTerm != LongTermLevel.None ? "Signing and getting the long-term data…" : choice.Timestamp ? "Signing and getting a timestamp…" : "Signing…");
            var request = new SignRequest
            {
                Certificate = cert,
                FieldName = field,
                PageIndex = box?.PageIndex ?? 0,
                Rect = box?.Rect,
                Reason = choice.Reason,
                Location = choice.Location,
                Look = choice.Look,
                Timestamp = choice.Timestamp ? client.TimestampSender(choice.TimestampUrl) : null,
                Certify = choice.Certify,
                LongTerm = choice.LongTerm,
                LongTermClient = choice.LongTerm != LongTermLevel.None ? client : null,
            };
            var outcome = await t.ApplySignatureAsync(request);
            if (outcome == EditOutcome.Declined) ShowStatus("Signing cancelled"); // e.g. the PIN prompt was cancelled
            if (outcome != EditOutcome.Done || t.IsDisposed) return;

            // The signature must be the file's last change: save the signed bytes as they are.
            var name = Path.GetFileNameWithoutExtension(t.Session.DisplayName);
            if (!await SaveAsDialogAsync(t, name.EndsWith("-signed", StringComparison.OrdinalIgnoreCase) ? name + ".pdf" : name + "-signed.pdf"))
            {
                if (!t.IsDisposed && t.Session.UndoLabel == "Sign") t.Undo();
                ShowStatus("Not signed: the signed copy wasn't saved");
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
                Prompt.Info(this, "Protected PDFs can't take long-term data",
                    "An update can't be appended to an encrypted PDF without breaking its signatures, so nothing can be added to this file.");
                return;
            }
            var data = t.Session.Data;
            var password = t.Session.Password;
            using var client = NewLtvClient();
            var plan = await Task.Run(() => Ltv.Plan(data, password, client));
            if (t.IsDisposed) return;
            var url = LtvDialogs.ConfirmAdd(this, plan, client);
            if (url is null) return;
            ShowStatus("Getting the long-term data…");
            var (outcome, result) = await t.AddVerificationAsync(client, url.Length == 0 ? null : url);
            if (outcome != EditOutcome.Done || result is null || t.IsDisposed) return;
            if (!result.Changed)
            {
                // Same bytes back: nothing to keep in the undo list or to save.
                if (t.Session.UndoLabel == "Add Verification Information") t.Undo();
                t.ShowLongTermOutcome("The file already holds everything that could be added. It wasn't changed.", LtvDialogs.Describe(result.Certificates, result.Contacts));
                return;
            }
            // The data must be the file's last change for the signatures to read as they do: save the bytes as they are.
            var name = Path.GetFileNameWithoutExtension(t.Session.DisplayName);
            if (!await SaveAsDialogAsync(t, name.EndsWith("-ltv", StringComparison.OrdinalIgnoreCase) ? name + ".pdf" : name + "-ltv.pdf"))
            {
                if (!t.IsDisposed && t.Session.UndoLabel == "Add Verification Information") t.Undo();
                ShowStatus("Not added: the copy wasn't saved");
                return;
            }
            var gaps = result.Certificates.Count(c => !c.Covered);
            t.ShowLongTermOutcome(gaps == 0 ? "Long-term data added." : $"Long-term data added, but {gaps} certificate{(gaps == 1 ? " has" : "s have")} none: see what was asked.",
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
            using var client = NewLtvClient();
            var plan = await Task.Run(() => Ltv.Plan(data, password, client, onlyMissing: false));
            if (t.IsDisposed || !LtvDialogs.ConfirmOnline(this, plan)) return;
            ShowStatus("Checking the signatures online…");
            LtvOnlineResult result;
            using (t.BeginBusy("Checking the signatures online…"))
                result = await Task.Run(() => Ltv.CheckOnlineAsync(data, password, client));
            if (!t.IsDisposed) t.ShowOnlineCheck(result);
        }
        catch (Exception ex) when (ex is SigningException or LtvFetchException)
        {
            Prompt.Error(this, "The check didn't work", ex.Message);
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
            System.Windows.Automation.AutomationProperties.SetName(item, $"Place {s.Name}");
            item.Click += (_, _) => t.BeginPlaceSignature(sig);
            menu.Items.Add(item);
        }
        if (menu.Items.Count > 0) menu.Items.Add(new Separator());
        var signatures = saved.Count(s => !s.Initials);
        var add = new MenuItem { Header = "Add a _signature…", IsEnabled = signatures < SignatureLibrary.MaxSignatures };
        if (!add.IsEnabled) add.ToolTip = $"Up to {SignatureLibrary.MaxSignatures} signatures: delete one first.";
        add.Click += (_, _) => CaptureSignature(t, initials: false);
        menu.Items.Add(add);
        var initials = new MenuItem { Header = saved.Any(s => s.Initials) ? "Replace the _initials…" : "Add _initials…" };
        initials.Click += (_, _) => CaptureSignature(t, initials: true);
        menu.Items.Add(initials);
        if (saved.Count > 0)
        {
            var delete = new MenuItem { Header = "_Delete a saved signature" };
            foreach (var s in saved)
            {
                var sig = s;
                var d = new MenuItem { Header = s.Name };
                d.Click += (_, _) =>
                {
                    if (!Prompt.Confirm(this, $"Delete {sig.Name}?", "It is removed from this PC. Signatures already placed in documents stay.", "Delete")) return;
                    try
                    {
                        SignatureLibrary.Delete(sig);
                    }
                    catch (Exception ex) when (ex is IOException or UnauthorizedAccessException)
                    {
                        Prompt.Error(this, "Couldn't delete it", ex.Message);
                    }
                };
                delete.Items.Add(d);
            }
            menu.Items.Add(delete);
        }
        menu.Items.Add(new Separator());
        menu.Items.Add(new MenuItem { Command = Cmd.Sign, CommandTarget = this });

        menu.PlacementTarget = FillSignButton.IsVisible ? FillSignButton : this;
        menu.Placement = FillSignButton.IsVisible ? PlacementMode.Bottom : PlacementMode.Center;
        menu.Closed += (_, _) => UpdateUi();
        menu.IsOpen = true;
        FillSignButton.IsChecked = true;
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
            Prompt.Error(this, "Couldn't save the signature", ex.Message);
            return;
        }
        if (saved is null)
        {
            Prompt.Info(this, "No room for another signature", $"Up to {SignatureLibrary.MaxSignatures} signatures can be saved: delete one first.");
            return;
        }
        t.BeginPlaceSignature(saved);
    }
}
