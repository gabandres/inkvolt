namespace InkvoltPdf.Core;

/// <summary>How an edit transaction ended (see <see cref="DocumentSession.EditAsync"/>).</summary>
public enum EditOutcome
{
    /// <summary>Committed as one undo step.</summary>
    Done,
    /// <summary>The edit returned the bytes it was given: nothing to commit, no undo step.</summary>
    NoChange,
    /// <summary>Another edit (or its questions) holds the document: try again once it is done.</summary>
    Busy,
    /// <summary>The user said no to a question (password, signatures), or cancelled a long edit: nothing changed.</summary>
    Declined,
    /// <summary>The edit threw (see <see cref="EditResult.Error"/>), the document isn't a PDF, or it was closed meanwhile.</summary>
    Failed,
}

/// <summary>What <see cref="DocumentSession.EditAsync"/> did.</summary>
/// <param name="StepId">The undo step a <see cref="EditOutcome.Done"/> edit made (compare with <see cref="DocumentSession.UndoStepId"/>).</param>
/// <param name="RemovedItemKept">See <see cref="SignedEditReport.RemovedItemKept"/>: the removed item can still be recovered from the signed revision.</param>
/// <param name="Error">Why a <see cref="EditOutcome.Failed"/> edit failed, when it threw.</param>
public readonly record struct EditResult(EditOutcome Outcome, long StepId = 0, bool RemovedItemKept = false, Exception? Error = null);

/// <summary>One edit for <see cref="DocumentSession.EditAsync"/>.</summary>
/// <param name="Label">Names the undo step ("Rotate pages"), and the questions asked about it.</param>
/// <param name="Edit">The edited bytes from the document's bytes and password; runs on a worker thread, and again after a
/// question was answered (a password, a rewrite allowed). Returning the same array means nothing changed.</param>
public sealed record EditRequest(string Label, Func<byte[], string?, byte[]> Edit)
{
    /// <summary>A form value or Fill &amp; Sign edit: the pages stay as they were (<see cref="ContentChange.ContentOnlyEdit"/>).</summary>
    public bool ContentOnly { get; init; }

    /// <summary>The caller already told the user the edit breaks the signatures (redaction): don't ask again.</summary>
    public bool SignaturesWarned { get; init; }

    /// <summary>The edit changes the protection (protect, unprotect): the passwords that open the result.</summary>
    public (string? Password, string? OpenPassword)? NewPasswords { get; init; }
}

/// <summary>The open password an edit of an AES-256 document needs, or the choice to save it without one.</summary>
public sealed record OpenPasswordAnswer(string? Password, bool DropIt);

/// <summary>
/// The questions an edit transaction asks the user. Each is asked on the thread that called
/// <see cref="DocumentSession.EditAsync"/>, at most once per answer it needs; a "no" (false, null) declines the edit.
/// The app's adapter shows dialogs; tests answer from a script.
/// </summary>
public interface IEditPrompts
{
    /// <summary>Before the first edit of an encrypted signed document (always rewritten): any change invalidates its signatures.</summary>
    bool ConfirmSignedEdit();

    /// <summary>An AES-256 document opened with its permissions password: its open password (checked against
    /// <paramref name="data"/>), or the choice to save without one. Null declines.</summary>
    OpenPasswordAnswer? AskOpenPassword(byte[] data);

    /// <summary>The document opened for viewing without its permissions (owner) password: ask for it.
    /// <paramref name="wrong"/>: the one tried was wrong. Null declines.</summary>
    string? AskOwnerPassword(bool wrong);

    /// <summary>The edit can't be appended to the signed file: saving it rewrites the file and invalidates
    /// <paramref name="signatures"/> signatures. <paramref name="reason"/> says why, for the log.</summary>
    bool ConfirmSignatureRewrite(string label, int signatures, string reason);

    /// <summary>The edit alters what intact signatures signed (they would show as invalid afterwards).</summary>
    bool ConfirmBreakingEdit(string label, IReadOnlyList<SignatureInfo> broken);
}

/// <summary>Why <see cref="DocumentSession.ContentChanged"/> was raised.</summary>
public enum ContentChange
{
    Edit,
    /// <summary>An edit that leaves the pages as they were (form values, Fill &amp; Sign): an open field editor can stay.</summary>
    ContentOnlyEdit,
    Undo,
    Redo,
    Reload,
}

public sealed class ContentChangedEventArgs(ContentChange change) : EventArgs
{
    public ContentChange Change { get; } = change;
    public bool ContentOnly => Change == ContentChange.ContentOnlyEdit;
    /// <summary>Undo or redo: the same page positions may now hold different pages.</summary>
    public bool SteppedHistory => Change is ContentChange.Undo or ContentChange.Redo;
}

public sealed partial class DocumentSession
{
    private bool _editing;
    private bool _signedEditAccepted;

    /// <summary>
    /// The document had valid-looking signatures when it was opened (or last reloaded). Set by whoever verified them
    /// (verifying takes a while, so it isn't done here); edits then check which signatures they would break.
    /// </summary>
    public bool SignedOnOpen { get; set; }

    /// <summary>An edit is running (its questions included): another one now returns <see cref="EditOutcome.Busy"/>.</summary>
    public bool IsEditing => _editing;

    /// <summary>
    /// Edits of a signed document are appended after the signed bytes (incremental update), which keeps the signatures
    /// valid. An encrypted signed document is always rewritten: that is said once, before its first edit. Any other edit
    /// that can't be appended stops with <see cref="SignaturesWouldBreakException"/> and asks before it is redone as a
    /// rewrite. Redaction warns on its own (<see cref="EditRequest.SignaturesWarned"/>).
    /// </summary>
    private bool NeedsSignedWarning => SignedOnOpen && !_signedEditAccepted && Engine.IsEncrypted;

    /// <summary>
    /// The edit transaction: runs <paramref name="request"/>'s edit on a worker thread and commits it as one undo step.
    /// On the way it keeps an encrypted document's protection (<see cref="KeptProtection"/>) and a signed document's
    /// signatures where it can (<see cref="SignedEdits"/>), asking <paramref name="prompts"/> what only the user can
    /// answer: the permissions or open password an edit needs (then the same edit runs again with it), whether to rewrite
    /// a signed file, whether to break signatures. A password that worked is used for later edits too.
    /// Never throws for a failed edit: see <see cref="EditResult.Error"/>.
    /// </summary>
    /// <param name="working">Called once the up-front question (a signed encrypted file) is answered and the edit starts:
    /// the app shows its progress from then on.</param>
    public async Task<EditResult> EditAsync(EditRequest request, IEditPrompts prompts, Action? working = null)
    {
        if (!IsPdf || _disposed) return new(EditOutcome.Failed);
        if (_editing) return new(EditOutcome.Busy);
        _editing = true;
        try
        {
            if (NeedsSignedWarning)
            {
                if (!prompts.ConfirmSignedEdit()) return new(EditOutcome.Declined);
                _signedEditAccepted = true;
                if (_disposed) return new(EditOutcome.Failed);
            }
            working?.Invoke();
            return await RunEdit(request, prompts);
        }
        finally
        {
            _editing = false;
        }
    }

    private async Task<EditResult> RunEdit(EditRequest request, IEditPrompts prompts)
    {
        var label = request.Label;
        try
        {
            var data = Data;
            var password = Password;
            byte[] result;
            SignedEditReport report;
            var rewrite = _signedEditAccepted; // already accepted that edits break the signatures (encrypted signed file)
            // An encrypted document keeps its protection through the edit; AES-256 opened with the owner password needs
            // its open password for that (asked once, see KeptProtection).
            var openPassword = OpenPassword;
            var dropOpenPassword = false;
            while (true)
            {
                try
                {
                    var (allowRewrite, open, drop, pw) = (rewrite, openPassword, dropOpenPassword, password);
                    (result, report) = await Task.Run(() => KeptProtection.Run(open, drop, () => SignedEdits.Run(() => request.Edit(data, pw), allowRewrite)));
                    break;
                }
                catch (OpenPasswordUnknownException) when (!_disposed)
                {
                    switch (prompts.AskOpenPassword(data))
                    {
                        case null:
                            return new(EditOutcome.Declined);
                        case { DropIt: true }:
                            dropOpenPassword = true;
                            break;
                        case { Password: var given }:
                            openPassword = given;
                            break;
                    }
                }
                catch (OwnerPasswordRequiredException ex) when (!_disposed)
                {
                    // Opened for viewing without the permissions password: ask for it and try the same edit again.
                    if (prompts.AskOwnerPassword(ex.WrongPassword) is not { } owner) return new(EditOutcome.Declined);
                    password = owner;
                }
                catch (SignaturesWouldBreakException ex) when (!_disposed && !rewrite)
                {
                    // The edit can't be appended to the signed file: say so before anything is committed, then redo it as a rewrite.
                    if (!prompts.ConfirmSignatureRewrite(label, ex.SignatureCount, ex.Reason)) return new(EditOutcome.Declined);
                    rewrite = true;
                }
            }
            if (_disposed) return new(EditOutcome.Failed);
            if (password is not null && password != Password) UsePassword(password); // only once it worked
            if (openPassword != OpenPassword) UseOpenPassword(openPassword);
            if (ReferenceEquals(result, data)) return new(EditOutcome.NoChange);
            // Signed document: an edit a signature doesn't allow (a page change, or one that couldn't be appended and
            // rewrites the file) shows that signature as invalid from then on. Say so before it happens.
            if (SignedOnOpen && !request.SignaturesWarned && !rewrite)
            {
                var pw = password;
                var broken = await Task.Run(() => Signatures.BrokenByEdits(Signatures.Verify(data, pw), result, pw));
                if (_disposed) return new(EditOutcome.Failed);
                if (broken.Count > 0 && !prompts.ConfirmBreakingEdit(label, broken)) return new(EditOutcome.Declined);
            }
            var change = request.ContentOnly ? ContentChange.ContentOnlyEdit : ContentChange.Edit;
            var id = request.NewPasswords is { } np
                ? Commit(result, label, np.Password, np.OpenPassword, change)
                : Commit(result, label, Password, dropOpenPassword ? null : OpenPassword, change);
            return new(EditOutcome.Done, id, report.RemovedItemKept);
        }
        catch (OperationCanceledException)
        {
            return new(EditOutcome.Declined); // the user cancelled a long edit (e.g. text recognition): nothing changed
        }
        catch (Exception ex) // the caller reports it; never lose it
        {
            return new(EditOutcome.Failed, Error: ex);
        }
    }
}
