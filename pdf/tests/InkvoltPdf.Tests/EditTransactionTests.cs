using InkvoltPdf.Core;
using PdfSharp.Pdf.IO;
using PdfSharp.Pdf.Security;

namespace InkvoltPdf.Tests;

/// <summary>
/// The edit transaction (<see cref="DocumentSession.EditAsync"/>) through its interface: the request, the questions it
/// asks (<see cref="IEditPrompts"/>, answered by <see cref="ScriptedPrompts"/>) and the session afterwards.
/// </summary>
public class EditTransactionTests
{
    /// <summary>Answers the transaction's questions from fixed answers and records what it was asked.</summary>
    private sealed class ScriptedPrompts : IEditPrompts
    {
        public bool SignedEdit = true;
        public Queue<OpenPasswordAnswer?> OpenPasswords = new();
        public Queue<string?> OwnerPasswords = new();
        public bool Rewrite = true;
        public bool Breaking = true;
        public List<string> Asked = [];

        public bool ConfirmSignedEdit()
        {
            Asked.Add("signed");
            return SignedEdit;
        }

        public OpenPasswordAnswer? AskOpenPassword(byte[] data)
        {
            Asked.Add("open");
            return OpenPasswords.Dequeue();
        }

        public string? AskOwnerPassword(bool wrong)
        {
            Asked.Add(wrong ? "owner (wrong)" : "owner");
            return OwnerPasswords.Dequeue();
        }

        public bool ConfirmSignatureRewrite(string label, int signatures, string reason)
        {
            Asked.Add($"rewrite {signatures}");
            return Rewrite;
        }

        public bool ConfirmBreakingEdit(string label, IReadOnlyList<SignatureInfo> broken)
        {
            Asked.Add($"breaks {string.Join(",", broken.Select(b => b.FieldName))}");
            return Breaking;
        }
    }

    private static EditRequest Rotate(string label = "Rotate") => new(label, (d, pw) => PageEditor.Rotate(d, pw, [0], 90));

    private static bool Landscape(DocumentSession s) => s.Engine.GetPage(0).Width > s.Engine.GetPage(0).Height;

    [Fact]
    public async Task AnEditIsOneUndoStepThatKeepsItsIdThroughUndoAndRedo()
    {
        using var session = DocumentSession.FromBytes(TestPdf.Make(2), "t.pdf");
        var prompts = new ScriptedPrompts();
        var changes = new List<ContentChange>();
        session.ContentChanged += (_, e) => changes.Add(e.Change);
        var working = 0;

        var first = await session.EditAsync(Rotate("Rotate"), prompts, () => working++);
        var second = await session.EditAsync(new EditRequest("Delete page", (d, pw) => PageEditor.Delete(d, pw, [1])), prompts);

        Assert.Equal(EditOutcome.Done, first.Outcome);
        Assert.Equal(1, working);
        Assert.NotEqual(first.StepId, second.StepId);
        Assert.Equal(second.StepId, session.UndoStepId);
        Assert.Equal("Delete page", session.UndoLabel);
        Assert.Equal(1, session.Engine.PageCount);
        Assert.True(Landscape(session));
        Assert.True(session.IsDirty);

        session.Undo();
        Assert.Equal(first.StepId, session.UndoStepId);
        Assert.Equal("Delete page", session.RedoLabel);
        Assert.Equal(2, session.Engine.PageCount);
        session.Undo();
        Assert.Null(session.UndoStepId);
        Assert.False(Landscape(session));
        session.Redo();
        session.Redo();
        Assert.Equal(second.StepId, session.UndoStepId); // the same edit again, not a new one
        Assert.Equal(1, session.Engine.PageCount);

        Assert.Equal([ContentChange.Edit, ContentChange.Edit, ContentChange.Undo, ContentChange.Undo, ContentChange.Redo, ContentChange.Redo], changes);
        Assert.Empty(prompts.Asked);
    }

    [Fact]
    public async Task ContentOnlyEditsSaySoAndUnchangedBytesMakeNoStep()
    {
        var form = Core2Pdf.Form(["<< /Type /Annot /Subtype /Widget /FT /Tx /T (name) /Rect [72 600 472 630] /DA (/Helv 12 Tf 0 g) /P 3 0 R >>"]);
        using var session = DocumentSession.FromBytes(form, "f.pdf");
        var args = new List<ContentChangedEventArgs>();
        session.ContentChanged += (_, e) => args.Add(e);
        var prompts = new ScriptedPrompts();

        var fill = new EditRequest("Fill form field", (d, pw) => FormEditor.Fill(d, pw, new Dictionary<string, string> { ["name"] = "Ada" }).Data) { ContentOnly = true };
        Assert.Equal(EditOutcome.Done, (await session.EditAsync(fill, prompts)).Outcome);
        Assert.True(Assert.Single(args).ContentOnly);
        session.Undo();
        Assert.False(args[1].ContentOnly); // undo replaces the pages
        Assert.True(args[1].SteppedHistory);

        var depthBefore = session.UndoStepId;
        var same = await session.EditAsync(new EditRequest("Nothing", (d, _) => d), prompts);
        Assert.Equal(EditOutcome.NoChange, same.Outcome);
        Assert.Equal(depthBefore, session.UndoStepId);
        Assert.Equal(2, args.Count);
    }

    [Fact]
    public async Task FailuresAndCancellationsCommitNothing()
    {
        using var session = DocumentSession.FromBytes(TestPdf.Make(1), "t.pdf");
        var prompts = new ScriptedPrompts();
        var failed = await session.EditAsync(new EditRequest("Break", (_, _) => throw new InvalidOperationException("nope")), prompts);
        Assert.Equal(EditOutcome.Failed, failed.Outcome);
        Assert.Equal("nope", failed.Error?.Message);
        var cancelled = await session.EditAsync(new EditRequest("Recognize", (_, _) => throw new OperationCanceledException()), prompts);
        Assert.Equal(EditOutcome.Declined, cancelled.Outcome);
        Assert.Null(cancelled.Error);
        Assert.False(session.CanUndo);
        Assert.False(session.IsEditing);
    }

    [Fact]
    public async Task OneEditAtATime()
    {
        using var session = DocumentSession.FromBytes(TestPdf.Make(1), "t.pdf");
        var prompts = new ScriptedPrompts();
        using var started = new ManualResetEventSlim();
        using var release = new ManualResetEventSlim();
        var slow = session.EditAsync(new EditRequest("Slow", (d, pw) =>
        {
            started.Set();
            release.Wait();
            return PageEditor.Rotate(d, pw, [0], 90);
        }), prompts);
        started.Wait();
        Assert.True(session.IsEditing);
        Assert.Equal(EditOutcome.Busy, (await session.EditAsync(Rotate(), prompts)).Outcome);
        release.Set();
        Assert.Equal(EditOutcome.Done, (await slow).Outcome);
        Assert.Equal("Slow", session.UndoLabel);
    }

    [Fact]
    public async Task AsksForTheOwnerPasswordUntilItWorksAndKeepsIt()
    {
        using var doc = PdfReader.Open(new MemoryStream(TestPdf.Make(2)), PdfDocumentOpenMode.Modify);
        doc.SecuritySettings.OwnerPassword = "own";
        doc.SecuritySettings.PermitModifyDocument = false;
        using var ms = new MemoryStream();
        doc.Save(ms, false);
        using var session = DocumentSession.FromBytes(ms.ToArray(), "r.pdf");
        var prompts = new ScriptedPrompts { OwnerPasswords = new(["wrong", "own"]) };

        var result = await session.EditAsync(Rotate(), prompts);

        Assert.Equal(EditOutcome.Done, result.Outcome);
        Assert.Equal(["owner", "owner (wrong)"], prompts.Asked);
        Assert.Equal("own", session.Password);
        Assert.True(PdfSecurity.ReadSecurity(session.Data, "own").IsEncrypted); // still protected
        Assert.Equal(EditOutcome.Done, (await session.EditAsync(Rotate("Again"), prompts)).Outcome);
        Assert.Equal(2, prompts.Asked.Count); // not asked again

        var cancelled = new ScriptedPrompts { OwnerPasswords = new([null]) };
        using var other = DocumentSession.FromBytes(ms.ToArray(), "r.pdf");
        Assert.Equal(EditOutcome.Declined, (await other.EditAsync(Rotate(), cancelled)).Outcome);
        Assert.False(other.CanUndo);
    }

    [Fact]
    public async Task AnAes256EditAsksForTheOpenPasswordAndKeepsTheProtection()
    {
        var pdf = KeptProtectionTests.Encrypted(PdfDefaultEncryption.V5, "secret");
        using var session = DocumentSession.FromBytes(pdf, "a.pdf", KeptProtectionTests.Owner);
        var prompts = new ScriptedPrompts { OpenPasswords = new([new OpenPasswordAnswer("secret", false)]) };

        Assert.Equal(EditOutcome.Done, (await session.EditAsync(Rotate(), prompts)).Outcome);
        Assert.Equal(["open"], prompts.Asked);
        Assert.Equal("secret", session.OpenPassword);
        var info = PdfSecurity.ReadSecurity(session.Data, "secret");
        Assert.Equal(EncryptionMethod.Aes256, info.Method);
        Assert.True(info.RequiresOpenPassword);
        Assert.Equal(EditOutcome.Done, (await session.EditAsync(Rotate("Again"), prompts)).Outcome);
        Assert.Single(prompts.Asked); // remembered

        // Or saved without an open password: the permissions password and restrictions stay.
        using var dropping = DocumentSession.FromBytes(pdf, "a.pdf", KeptProtectionTests.Owner);
        var drop = new ScriptedPrompts { OpenPasswords = new([new OpenPasswordAnswer(null, true)]) };
        Assert.Equal(EditOutcome.Done, (await dropping.EditAsync(Rotate(), drop)).Outcome);
        Assert.Null(dropping.OpenPassword);
        Assert.False(PdfSecurity.ReadSecurity(dropping.Data, null).RequiresOpenPassword);
        Assert.True(PdfSecurity.ReadSecurity(dropping.Data, null).IsEncrypted);

        using var declining = DocumentSession.FromBytes(pdf, "a.pdf", KeptProtectionTests.Owner);
        Assert.Equal(EditOutcome.Declined, (await declining.EditAsync(Rotate(), new ScriptedPrompts { OpenPasswords = new([null]) })).Outcome);
        Assert.False(declining.CanUndo);
    }

    [Fact]
    public async Task ProtectionChangesCommitTheirPasswordsAndUndoRestoresThem()
    {
        var plain = TestPdf.Make(1);
        using var session = DocumentSession.FromBytes(plain, "p.pdf");
        var protect = new EditRequest("Protect", (d, pw) => PdfSecurity.Protect(d, pw, "open", "own")) { NewPasswords = ("own", "open") };
        Assert.Equal(EditOutcome.Done, (await session.EditAsync(protect, new ScriptedPrompts())).Outcome);
        Assert.Equal(("own", "open"), (session.Password, session.OpenPassword));
        Assert.True(PdfSecurity.ReadSecurity(session.Data, "open").RequiresOpenPassword);
        // A later edit keeps it protected.
        Assert.Equal(EditOutcome.Done, (await session.EditAsync(Rotate(), new ScriptedPrompts())).Outcome);
        Assert.True(PdfSecurity.ReadSecurity(session.Data, "open").RequiresOpenPassword);
        session.Undo();
        session.Undo();
        Assert.Equal((null, null), (session.Password, session.OpenPassword));
        Assert.False(session.Engine.IsEncrypted);
    }

    [Fact]
    public async Task ASignedFileAsksBeforeAnEditBreaksItsSignature()
    {
        var pdf = SignedEditTests.Signed();
        using var session = DocumentSession.FromBytes(pdf, "s.pdf");
        session.SignedOnOpen = true;
        var no = new ScriptedPrompts { Breaking = false };

        // A comment is appended: the signature stays valid, nothing to ask.
        var note = new EditRequest("Add note", (d, pw) => Annotations.AddNote(d, pw, 0, 100, 100, "Hi", "Me"));
        var noted = await session.EditAsync(note, no);
        Assert.Equal(EditOutcome.Done, noted.Outcome);
        Assert.False(noted.RemovedItemKept);
        Assert.Empty(no.Asked);

        // Deleting a page alters what was signed.
        var before = session.Data;
        var delete = new EditRequest("Delete pages", (d, pw) => PageEditor.Delete(d, pw, [1]));
        Assert.Equal(EditOutcome.Declined, (await session.EditAsync(delete, no)).Outcome);
        Assert.Equal(["breaks Approval"], no.Asked);
        Assert.Same(before, session.Data);

        var yes = new ScriptedPrompts();
        var deleted = await session.EditAsync(delete, yes);
        Assert.Equal(EditOutcome.Done, deleted.Outcome);
        Assert.True(deleted.RemovedItemKept); // appended: the page is still in the signed revision
        Assert.Equal(1, session.Engine.PageCount);

        // Already warned (redaction): no question.
        session.Undo();
        var warned = new ScriptedPrompts();
        Assert.Equal(EditOutcome.Done, (await session.EditAsync(delete with { SignaturesWarned = true }, warned)).Outcome);
        Assert.Empty(warned.Asked);
    }

    [Fact]
    public async Task AnEditThatRewritesASignedFileAsksFirst()
    {
        using var session = DocumentSession.FromBytes(SignedEditTests.Signed(), "s.pdf");
        session.SignedOnOpen = true;
        var protect = new EditRequest("Protect", (d, pw) => PdfSecurity.Protect(d, pw, "open", "own")) { NewPasswords = ("own", "open") };

        var no = new ScriptedPrompts { Rewrite = false };
        Assert.Equal(EditOutcome.Declined, (await session.EditAsync(protect, no)).Outcome);
        Assert.Equal(["rewrite 1"], no.Asked);
        Assert.False(session.CanUndo);

        var yes = new ScriptedPrompts();
        Assert.Equal(EditOutcome.Done, (await session.EditAsync(protect, yes)).Outcome);
        Assert.Equal(["rewrite 1"], yes.Asked); // a rewrite the user allowed isn't asked about again as "breaking"
        Assert.True(session.Engine.IsEncrypted);
    }

    [Fact]
    public async Task AnEncryptedSignedFileWarnsOnceBeforeItsFirstEdit()
    {
        using var session = DocumentSession.FromBytes(SignedEditTests.Encrypted(SignedEditTests.Signed()), "e.pdf", "owner");
        session.SignedOnOpen = true;

        var no = new ScriptedPrompts { SignedEdit = false };
        var working = 0;
        Assert.Equal(EditOutcome.Declined, (await session.EditAsync(Rotate(), no, () => working++)).Outcome);
        Assert.Equal(["signed"], no.Asked);
        Assert.Equal(0, working); // the edit never started

        var yes = new ScriptedPrompts();
        Assert.Equal(EditOutcome.Done, (await session.EditAsync(Rotate(), yes)).Outcome);
        Assert.Equal(EditOutcome.Done, (await session.EditAsync(Rotate("Again"), yes)).Outcome);
        Assert.Equal(["signed"], yes.Asked); // once, then edits rewrite without asking
        Assert.True(session.Engine.IsEncrypted);
    }

    [Fact]
    public async Task OnlyPdfsAndOpenSessionsAreEdited()
    {
        var session = DocumentSession.FromBytes(TestPdf.Make(1), "t.pdf");
        session.Dispose();
        Assert.Equal(EditOutcome.Failed, (await session.EditAsync(Rotate(), new ScriptedPrompts())).Outcome);
    }
}
