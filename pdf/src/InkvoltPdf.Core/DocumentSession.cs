using MuPDFCore;

namespace InkvoltPdf.Core;

/// <summary>
/// An open document: its bytes, the MuPDF view of them, and undo/redo snapshots of page edits. The file on disk is
/// read once and never locked; it changes only on Save. Edits go through <see cref="EditAsync"/> (the edit transaction,
/// in DocumentSession.Edit.cs).
/// </summary>
public sealed partial class DocumentSession : IDisposable
{
    private const int MaxUndoSteps = 50;
    private const long MaxUndoBytes = 768L * 1024 * 1024;

    /// <summary>An undo/redo state: its bytes, and the passwords that open them (a protection change swaps them).</summary>
    /// <remarks><paramref name="Id"/> names the edit: it stays with the step through undo and redo.</remarks>
    private readonly record struct Step(byte[] Data, string Label, int Version, string? Password, string? OpenPassword, long Id);

    private readonly LinkedList<Step> _undo = new();
    private readonly Stack<Step> _redo = new();
    private int _version;
    private int _savedVersion;
    private int _nextVersion = 1;
    private long _lastStepId;
    private bool _disposed;
    private (long Length, DateTime WriteTimeUtc)? _onDisk;
    private string? _diskPassword; // what opens the file on disk: the session's own may differ after a protection change

    public string? FilePath { get; private set; }
    public string DisplayName { get; private set; }
    public byte[] Data { get; private set; }
    /// <summary>The password the document was opened with; replaced by the permissions password once the user gives it for an edit.</summary>
    public string? Password { get; private set; }
    /// <summary>
    /// The document's open (user) password when known: given to open it, or entered so an edit could keep it. Edits of
    /// an AES-256 file opened with its owner password need it (<see cref="KeptProtection.Run{T}"/>).
    /// </summary>
    public string? OpenPassword { get; private set; }
    public InputFileTypes FileType { get; }
    public PdfEngine Engine { get; private set; }
    /// <summary>True when the content differs from what is on disk (undoing back to the saved state clears it).</summary>
    public bool IsDirty => _version != _savedVersion;
    public bool IsPdf => FileType == InputFileTypes.PDF;

    private sealed record EncryptionScan(byte[] Data, bool Found);
    private EncryptionScan? _encryptionScan;

    /// <summary>
    /// True when the PDF has an encryption dictionary: it needs a password to open, or only restricts printing, copying or
    /// editing. <see cref="PdfEngine.IsEncrypted"/> is true only in the first case (MuPDF opens the others as plain).
    /// Remove Protection applies to both; signing refuses both. A byte scan as signing's own, cached per content.
    /// </summary>
    public bool HasEncryption
    {
        get
        {
            var data = Data;
            if (_encryptionScan is { } scan && ReferenceEquals(scan.Data, data)) return scan.Found;
            var found = IsPdf && data.AsSpan().IndexOf("/Encrypt"u8) >= 0;
            _encryptionScan = new EncryptionScan(data, found);
            return found;
        }
    }

    /// <summary>The file's size and time when it was opened or last saved (null for a document never saved).</summary>
    public (long Length, DateTime WriteTimeUtc)? DiskStampWhenRead => _onDisk;

    public bool CanUndo => _undo.Count > 0;
    public bool CanRedo => _redo.Count > 0;
    public string? UndoLabel => _undo.Last?.Value.Label;
    /// <summary>
    /// The edit that <see cref="Undo"/> would take back (what <see cref="EditResult.StepId"/> returned when it was made),
    /// or null: lets a toast's Undo act only on the very edit it announced.
    /// </summary>
    public long? UndoStepId => _undo.Last?.Value.Id;
    public string? RedoLabel => _redo.TryPeek(out var r) ? r.Label : null;

    /// <summary>Raised after the document content changed (edit, undo, redo, reload); the engine has been replaced.</summary>
    public event EventHandler<ContentChangedEventArgs>? ContentChanged;

    /// <summary>Raised when the name, path or dirty state changed.</summary>
    public event EventHandler? StateChanged;

    private DocumentSession(string? path, string displayName, byte[] data, string? password, InputFileTypes type, PdfEngine engine)
    {
        FilePath = path;
        DisplayName = displayName;
        Data = data;
        Password = password;
        FileType = type;
        Engine = engine;
    }

    /// <exception cref="PasswordRequiredException"/>
    public static DocumentSession Open(string path, string? password = null)
    {
        // Stamp before reading: a write that lands mid-read then shows up as a change rather than going unnoticed.
        var stamp = DiskStamp(path);
        var data = File.ReadAllBytes(path);
        var type = PdfEngine.TypeFromPath(path);
        var engine = PdfEngine.Open(data, type, password);
        var openPassword = type == InputFileTypes.PDF && PdfSecurity.IsOpenPassword(data, password) ? password : null;
        return new DocumentSession(Path.GetFullPath(path), Path.GetFileName(path), data, password, type, engine) { _onDisk = stamp, OpenPassword = openPassword, _diskPassword = password };
    }

    /// <summary>A new, unsaved PDF (e.g. the result of Combine or Extract).</summary>
    public static DocumentSession FromBytes(byte[] data, string displayName, string? password = null)
    {
        var engine = PdfEngine.Open(data, InputFileTypes.PDF, password);
        var session = new DocumentSession(null, displayName, data, password, InputFileTypes.PDF, engine);
        session._savedVersion = -1; // never saved
        return session;
    }

    /// <summary>
    /// A document offered back after Inkvolt PDF closed without saving it (<see cref="RecoveryStore"/>): its bytes as they
    /// were, with unsaved changes, under the file it came from (null for one never saved), so Save writes it back there.
    /// <paramref name="diskStamp"/> is that file's size and time when the copy was made: a file changed since shows as
    /// changed on disk, as it would have in the run that made the copy.
    /// </summary>
    /// <exception cref="PasswordRequiredException"/>
    public static DocumentSession Recover(byte[] data, string? originalPath, string displayName, (long Length, DateTime WriteTimeUtc)? diskStamp = null,
        string? password = null)
    {
        var engine = PdfEngine.Open(data, InputFileTypes.PDF, password);
        var path = originalPath is null ? null : Path.GetFullPath(originalPath);
        var openPassword = PdfSecurity.IsOpenPassword(data, password) ? password : null;
        var session = new DocumentSession(path, displayName, data, password, InputFileTypes.PDF, engine) { OpenPassword = openPassword, _diskPassword = password };
        session._onDisk = path is null ? null : diskStamp ?? DiskStamp(path);
        session._savedVersion = -1; // unsaved changes
        return session;
    }

    /// <summary>Uses the permissions (owner) password for edits from now on (after <see cref="OwnerPasswordRequiredException"/>).</summary>
    /// <remarks>A different password that opened the document but couldn't edit it was its open (user) password.</remarks>
    public void UsePassword(string password)
    {
        if (!string.IsNullOrEmpty(Password) && Password != password && OpenPassword is null) OpenPassword = Password;
        Password = password;
    }

    /// <summary>Remembers the document's open password (entered so an edit keeps it).</summary>
    public void UseOpenPassword(string? openPassword) => OpenPassword = openPassword;

    /// <summary>Replaces the content with edited bytes, recording an undo step.</summary>
    public void Commit(byte[] newData, string label) => Commit(newData, label, Password, OpenPassword);

    /// <summary>
    /// Replaces the content with edited bytes that open with other passwords (the protection changed), recording an
    /// undo step: undoing it goes back to the old bytes and passwords.
    /// </summary>
    public void Commit(byte[] newData, string label, string? password, string? openPassword) =>
        Commit(newData, label, password, openPassword, ContentChange.Edit);

    /// <returns>The new undo step's id (<see cref="UndoStepId"/>).</returns>
    private long Commit(byte[] newData, string label, string? password, string? openPassword, ContentChange change)
    {
        var engine = PdfEngine.Open(newData, FileType, password);
        var id = ++_lastStepId;
        _undo.AddLast(new Step(Data, label, _version, Password, OpenPassword, id));
        TrimUndo();
        _redo.Clear();
        (Password, OpenPassword) = (password, openPassword);
        Swap(newData, engine, _nextVersion++, change);
        return id;
    }

    public void Undo()
    {
        if (_undo.Last is not { } node) return;
        var step = node.Value;
        var engine = PdfEngine.Open(step.Data, FileType, step.Password);
        _undo.RemoveLast();
        _redo.Push(step with { Data = Data, Version = _version, Password = Password, OpenPassword = OpenPassword });
        (Password, OpenPassword) = (step.Password, step.OpenPassword);
        Swap(step.Data, engine, step.Version, ContentChange.Undo);
    }

    public void Redo()
    {
        if (!_redo.TryPeek(out var step)) return;
        var engine = PdfEngine.Open(step.Data, FileType, step.Password);
        _redo.Pop();
        _undo.AddLast(step with { Data = Data, Version = _version, Password = Password, OpenPassword = OpenPassword });
        (Password, OpenPassword) = (step.Password, step.OpenPassword);
        Swap(step.Data, engine, step.Version, ContentChange.Redo);
    }

    /// <summary>
    /// Writes the current bytes to <paramref name="path"/> atomically: a flushed temp file in the same folder, then
    /// swapped in with File.Replace (which keeps the target's ACLs, attributes and creation time).
    /// </summary>
    /// <exception cref="UnauthorizedAccessException">The target is read-only (or access is denied).</exception>
    public void SaveAs(string path)
    {
        path = Path.GetFullPath(path);
        WriteFile(path, Data);
        MarkSaved(path, _version, Password);
    }

    /// <summary>
    /// <see cref="SaveAs"/> with the writing on a worker thread: the bytes as they are now are written, the session is
    /// updated on the calling thread afterwards. An edit committed meanwhile leaves the document dirty.
    /// </summary>
    public async Task SaveAsAsync(string path)
    {
        path = Path.GetFullPath(path);
        var (data, version, password) = (Data, _version, Password);
        await Task.Run(() => WriteFile(path, data));
        MarkSaved(path, version, password);
    }

    private void MarkSaved(string path, int version, string? password)
    {
        FilePath = path;
        _diskPassword = password;
        DisplayName = Path.GetFileName(path);
        _savedVersion = version;
        _onDisk = DiskStamp(path);
        StateChanged?.Invoke(this, EventArgs.Empty);
    }

    private static void WriteFile(string path, byte[] data)
    {
        var target = new FileInfo(path);
        if (target.Exists && target.IsReadOnly)
            throw new UnauthorizedAccessException($"\"{target.Name}\" is read-only. Save a copy under another name, or clear its read-only attribute.");

        var temp = Path.Combine(target.DirectoryName!, $".{target.Name}.{Guid.NewGuid():N}.tmp");
        try
        {
            using (var stream = new FileStream(temp, FileMode.CreateNew, FileAccess.Write, FileShare.None, 1 << 16))
            {
                stream.Write(data);
                stream.Flush(flushToDisk: true);
            }

            if (!File.Exists(path))
            {
                File.Move(temp, path);
            }
            else
            {
                try
                {
                    File.Replace(temp, path, destinationBackupFileName: null);
                }
                catch (IOException) when (File.Exists(temp))
                {
                    // Some file systems (FAT, certain network shares) can't replace; the target may already be gone.
                    File.Move(temp, path, overwrite: true);
                }
            }
        }
        finally
        {
            // Best effort: a failed cleanup must not hide the real error (or turn a completed save into a failure).
            try
            {
                if (File.Exists(temp)) File.Delete(temp);
            }
            catch (Exception ex) when (ex is IOException or UnauthorizedAccessException)
            {
            }
        }
    }

    /// <summary>True when the file is missing or its size or last-write time differ from when it was opened or last saved.</summary>
    public bool HasChangedOnDisk()
    {
        if (FilePath is null) return false;
        var now = DiskStamp(FilePath);
        return now is null || (_onDisk is { } then && now != then);
    }

    /// <summary>True when the document came from a file that no longer exists (moved, renamed or deleted).</summary>
    public bool IsMissingOnDisk() => FilePath is not null && !File.Exists(FilePath);

    /// <summary>
    /// Re-reads the file with the password that opened or saved it (not the session's own after Remove Protection or a
    /// new password), discarding unsaved changes and undo history; raises ContentChanged then StateChanged. On failure
    /// (I/O, password, corrupt file) nothing changes.
    /// </summary>
    /// <exception cref="PasswordRequiredException">The file needs another password (another program protected it).</exception>
    public void ReloadFromDisk() => ApplyReload(ReadDiskCopy(FilePath, FileType, _diskPassword));

    /// <summary>
    /// <see cref="ReloadFromDisk"/> with the reading and parsing on a worker thread; the content is swapped on the calling
    /// thread. Returns false (nothing changed) when <paramref name="stillWanted"/> says no once the file has been read.
    /// <paramref name="password"/>: one the user gave after <see cref="PasswordRequiredException"/>.
    /// </summary>
    public async Task<bool> ReloadFromDiskAsync(Func<bool>? stillWanted = null, string? password = null)
    {
        var (path, type) = (FilePath, FileType);
        password ??= _diskPassword;
        var copy = await Task.Run(() => ReadDiskCopy(path, type, password));
        if (stillWanted?.Invoke() == false || path != FilePath)
        {
            copy.Engine.Dispose();
            return false;
        }
        ApplyReload(copy);
        return true;
    }

    private sealed record DiskCopy(byte[] Data, PdfEngine Engine, (long, DateTime)? Stamp, string? Password, string? OpenPassword);

    private static DiskCopy ReadDiskCopy(string? path, InputFileTypes type, string? password)
    {
        if (path is null) throw new InvalidOperationException("This document has not been saved to a file.");
        var stamp = DiskStamp(path);
        var data = File.ReadAllBytes(path);
        var engine = PdfEngine.Open(data, type, password);
        var openPassword = type == InputFileTypes.PDF && PdfSecurity.IsOpenPassword(data, password) ? password : null;
        return new DiskCopy(data, engine, stamp, password, openPassword);
    }

    private void ApplyReload(DiskCopy copy)
    {
        // The file's passwords from now on; the same password keeps an open password learned since.
        if (copy.Password != Password) (Password, OpenPassword) = (copy.Password, copy.OpenPassword);
        _diskPassword = copy.Password;
        _undo.Clear();
        _redo.Clear();
        _onDisk = copy.Stamp;
        var version = _nextVersion++;
        _savedVersion = version;
        Swap(copy.Data, copy.Engine, version, ContentChange.Reload);
    }

    private static (long, DateTime)? DiskStamp(string path)
    {
        var info = new FileInfo(path);
        return info.Exists ? (info.Length, info.LastWriteTimeUtc) : null;
    }

    private void Swap(byte[] data, PdfEngine engine, int version, ContentChange change)
    {
        var old = Engine;
        Data = data;
        Engine = engine;
        _version = version;
        ContentChanged?.Invoke(this, new ContentChangedEventArgs(change));
        StateChanged?.Invoke(this, EventArgs.Empty);
        old.Dispose();
    }

    private void TrimUndo()
    {
        var total = _undo.Sum(u => (long)u.Data.Length);
        while (_undo.Count > 1 && (_undo.Count > MaxUndoSteps || total > MaxUndoBytes))
        {
            total -= _undo.First!.Value.Data.Length;
            _undo.RemoveFirst();
        }
    }

    public void Dispose()
    {
        _disposed = true;
        Engine.Dispose();
    }
}
