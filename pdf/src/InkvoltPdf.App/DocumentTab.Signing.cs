using System.Windows;
using System.Windows.Controls;
using InkvoltPdf.App.Viewer;
using InkvoltPdf.Core;

namespace InkvoltPdf.App;

/// <summary>Digital signing (placing the box, applying the signature) and handwritten signature stamps (Fill &amp; Sign).</summary>
public partial class DocumentTab
{
    private TaskCompletionSource<SignaturePlacement?>? _sigBoxWait;
    private StampImage? _pendingSigImage;
    private string _pendingSigLabel = "Signature";

    /// <summary>Asks the window to run "Sign Digitally": null = a new signature, else the empty field to sign.</summary>
    public event EventHandler<string?>? SignRequested;

    private void InitSigning()
    {
        Viewer.SignatureFieldActivated += (_, w) => OnSignatureField(w.FieldName);
        Viewer.SignatureBoxDrawn += (_, p) =>
        {
            if (_sigBoxWait is not { } wait) return;
            _sigBoxWait = null;
            Viewer.Tool = ViewerTool.Hand;
            wait.TrySetResult(p);
        };
        Viewer.ToolChanged += (_, _) =>
        {
            if (Viewer.Tool != ViewerTool.PlaceSignature && _sigBoxWait is { } wait)
            {
                _sigBoxWait = null;
                wait.TrySetResult(null);
            }
            if (Viewer.Tool != ViewerTool.AddSignature) _pendingSigImage = null;
        };
        Viewer.SignatureStampPlaced += (_, p) => _ = Viewer.Tool switch
        {
            ViewerTool.AddImage => PlaceImage(p),
            ViewerTool.AddStamp => PlaceStamp(p),
            _ => PlaceSignatureStamp(p),
        };
        Viewer.SignatureStampChanged += (_, c) => _ = ChangeSignatureStamp(c);
    }

    /// <summary>A signature field was clicked: an empty one is signed; a signed one shows its details.</summary>
    private void OnSignatureField(string fieldName)
    {
        var info = _signatures.FirstOrDefault(s => s.FieldName == fieldName);
        if (info is { Status: not SignatureStatus.Unsigned })
        {
            ShowSignatureDetails(fieldName);
            return;
        }
        SignRequested?.Invoke(this, fieldName);
    }

    /// <summary>Opens the Signatures pane with the field's entry selected.</summary>
    public void ShowSignatureDetails(string? fieldName)
    {
        _sigBarDismissed = false;
        ShowPane(NavPaneKind.Signatures);
        if (fieldName is null) return;
        var item = SignatureList.Items.OfType<SignatureItem>().FirstOrDefault(i => i.Info.FieldName == fieldName);
        if (item is null) return;
        _shownSignature = fieldName;
        Dispatcher.BeginInvoke(System.Windows.Threading.DispatcherPriority.Loaded, () =>
        {
            if (SignatureList.ItemContainerGenerator.ContainerFromItem(item) is FrameworkElement fe) fe.BringIntoView();
        });
        if (item.Info.PageIndex >= 0 && !item.Info.Rect.IsEmpty) Viewer.Flash(item.Info.PageIndex, item.Info.Rect);
    }

    private string? _shownSignature;

    private void OnSignField(object sender, RoutedEventArgs e)
    {
        if (sender is FrameworkElement { Tag: SignatureItem s } && !IsBusy) SignRequested?.Invoke(this, s.Info.FieldName);
    }

    /// <summary>The document's form widgets, as last read (for the fields a certifying signature can lock).</summary>
    public IReadOnlyList<FormWidget> FormWidgets { get; private set; } = [];

    /// <summary>The form fields a signature can lock: every field but signatures and buttons, each name once, in form order.</summary>
    public IReadOnlyList<string> LockableFields =>
        [.. FormWidgets.Where(w => w.Kind is not (FormFieldKind.Signature or FormFieldKind.PushButton)).Select(w => w.FieldName).Distinct(StringComparer.Ordinal)];

    /// <summary>The empty signature field <paramref name="fieldName"/>: its box (width/height) and whether it is visible.</summary>
    public (double Aspect, bool Visible) SignatureFieldShape(string fieldName)
    {
        var info = _signatures.FirstOrDefault(s => s.FieldName == fieldName);
        return info is null || info.Rect.IsEmpty ? (3.2, false) : (info.Rect.Width / info.Rect.Height, true);
    }

    /// <summary>Lets the user drag the visible signature's box on a page. Null when cancelled (Esc, another tool).</summary>
    public Task<SignaturePlacement?> PickSignatureBoxAsync()
    {
        _sigBoxWait?.TrySetResult(null);
        _sigBoxWait = null;
        SetOrganizing(false);
        Viewer.Tool = ViewerTool.PlaceSignature;
        var wait = new TaskCompletionSource<SignaturePlacement?>(TaskCreationOptions.RunContinuationsAsynchronously);
        _sigBoxWait = wait;
        Notify(Strings.TabSign_DragBox);
        Viewer.Focus();
        return wait.Task;
    }

    /// <summary>Signs the document (off the UI thread; smart card and Windows Hello PIN prompts come from Windows).</summary>
    public async Task<EditOutcome> ApplySignatureAsync(SignRequest request)
    {
        var outcome = await TryEdit(Strings.TabSign_EditSign, (d, pw) => Signing.Sign(d, pw, request), quiet: true, contentOnly: true);
        if (outcome == EditOutcome.Done) _sigBarDismissed = false;
        return outcome;
    }

    /// <summary>Add Verification Information on the document (off the UI thread). The result, when it ran.</summary>
    public async Task<(EditOutcome Outcome, LtvResult? Result)> AddVerificationAsync(LtvClient client, string? timestampUrl)
    {
        LtvResult? result = null;
        var outcome = await TryEdit(Strings.TabSign_EditAddVerification, (d, pw) =>
        {
            result = Ltv.AddVerificationAsync(d, pw, client, timestampUrl is null ? null : client.TimestampSender(timestampUrl), repairedLength: Session.RepairedLength).GetAwaiter().GetResult();
            return result.Pdf;
        }, quiet: true, contentOnly: true);
        if (outcome == EditOutcome.Done) _sigBarDismissed = false;
        return (outcome, result);
    }

    /// <summary>Revocation data the person asked for online: counts for this tab's view until the document changes hands. Not written anywhere.</summary>
    private RevocationSnapshot? _onlineRevocation;

    /// <summary>Shows what Check Signatures Online found, the file as it was.</summary>
    public void ShowOnlineCheck(LtvOnlineResult result)
    {
        _onlineRevocation = result.Snapshot;
        ShowLongTermOutcome(result.Problem is { } p ? Loc.Format(Strings.TabSign_CheckedOnlinePartly, p) : Strings.TabSign_CheckedOnline,
            LtvDialogs.Describe(result.Certificates, result.Contacts));
        _ = LoadReviewAsync();
    }

    /// <summary>Puts what long-term validation did at the top of the Signatures pane.</summary>
    public void ShowLongTermOutcome(string text, string details)
    {
        SigLtvOutcome.Text = text;
        SigLtvOutcome.Visibility = Visibility.Visible;
        SigLtvDetailsText.Text = details;
        SigLtvDetails.IsExpanded = false;
        SigLtvDetails.Visibility = Visibility.Visible;
        ShowPane(NavPaneKind.Signatures);
    }

    internal string DevLongTermOutcome => SigLtvOutcome.Visibility == Visibility.Visible ? $"{SigLtvOutcome.Text}\n{SigLtvDetailsText.Text}" : "";

    // ───────────────────────────── Handwritten signatures ─────────────────────────────

    /// <summary>Arms the Add signature tool with a saved signature: the next click on a page places it.</summary>
    public void BeginPlaceSignature(SavedSignature saved)
    {
        StampImage image;
        System.Windows.Media.Imaging.BitmapSource bmp;
        try
        {
            bmp = saved.Load();
            image = SignatureImages.ToStampImage(bmp);
        }
        catch (Exception ex) when (ex is System.IO.IOException or NotSupportedException or UnauthorizedAccessException)
        {
            Notify(Loc.Format(Strings.TabSign_SavedUnreadable, ex.Message), error: true);
            return;
        }
        SetOrganizing(false);
        var h = saved.Initials ? 28.0 : 42.0;
        var w = Math.Min(260, h * bmp.PixelWidth / Math.Max(1, bmp.PixelHeight));
        Viewer.SignatureStampSize = new Size(w, w * bmp.PixelHeight / Math.Max(1, bmp.PixelWidth));
        Viewer.Tool = ViewerTool.AddSignature;
        _pendingSigImage = image;
        _pendingSigLabel = saved.Initials ? "Initials" : "Signature";
        Notify(saved.Initials ? Strings.TabSign_ClickWhereInitials : Strings.TabSign_ClickWhereSignature);
        Viewer.Focus();
    }

    private async Task PlaceSignatureStamp(SignaturePlacement p)
    {
        if (_pendingSigImage is not { } image)
        {
            Notify(Strings.TabSign_ChooseFirst);
            return;
        }
        var label = _pendingSigLabel;
        Viewer.Tool = ViewerTool.Hand;
        await RunStampEdit(label == "Initials" ? Strings.TabSign_EditAddInitials : Strings.TabSign_EditAddSignature,
            (d, pw) => SignatureStamps.Put(d, pw, p.PageIndex, p.Rect, image, null, label));
    }

    /// <summary>A placed signature, picture or stamp moved, resized or deleted on the page.</summary>
    private Task ChangeSignatureStamp(SignatureStampChange c)
    {
        var kind = Viewer.PlacedStampKind(c.Id);
        if (c.Rect is not { } r)
            return RunStampEdit(kind switch { StampKind.Image => Strings.TabSign_EditRemoveImage, StampKind.Stamp => Strings.TabSign_EditRemoveStamp, _ => Strings.TabSign_EditRemoveSignature },
                (d, pw) => TextStamps.Remove(d, pw, c.Id));
        return kind == StampKind.Stamp
            ? RunStampEdit(Strings.TabSign_EditMoveStamp, (d, pw) => RubberStamps.Move(d, pw, c.Id, c.PageIndex, r))
            : RunStampEdit(kind == StampKind.Image ? Strings.TabSign_EditMoveImage : Strings.TabSign_EditMoveSignature, (d, pw) => SignatureStamps.Put(d, pw, c.PageIndex, r, null, c.Id));
    }

    /// <summary>An undoable stamp edit; waits while another edit (or its prompt) holds the tab.</summary>
    private async Task RunStampEdit(string label, Func<byte[], string?, byte[]> edit)
    {
        while (true)
        {
            while (IsBusy)
            {
                await WhenIdle();
                if (_disposed) return;
            }
            if (await TryEdit(label, edit, contentOnly: true) != EditOutcome.Busy || _disposed) return;
        }
    }

    internal IReadOnlyList<TextStamp> DevSignatureStamps => Viewer.DevSignatureStamps;

    /// <summary>The signature last shown in the Signatures pane (for scripts).</summary>
    internal string? DevShownSignature => _shownSignature;
}
