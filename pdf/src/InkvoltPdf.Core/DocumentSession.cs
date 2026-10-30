using MuPDFCore;

namespace InkvoltPdf.Core;

/// <summary>
/// An open document: its bytes, the MuPDF view of them, and undo/redo snapshots of page edits. The file on disk is
/// read once and never locked; it changes only on Save. A PDF of <see cref="InPlaceBytes"/> or more is the exception: it
/// opens in place (MuPDF reads the file as pages need it, other programs can't replace it meanwhile) and its bytes are
/// read only when something asks for <see cref="Data"/> (an edit's undo step, a reader of the file's structure); the first
/// edit, undo or reload lets the file go. Edits go through <see cref="EditAsync"/> (the edit transaction, in
/// DocumentSession.Edit.cs).
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

    /// <summary>PDFs this big or bigger open in place (see the class summary).</summary>
    public const long InPlaceBytes = 256L * 1024 * 1024;

    private long _inPlaceBytes = InPlaceBytes; // tests open small files in place

    /// <summary>
    /// The file a session opened in place reads, while the content is still that file's: the names its bytes mention
    /// (<see cref="MayContain"/>) are scanned on a worker as it opens.
    /// </summary>
    private sealed class InPlaceFile(string path, (long Length, DateTime WriteTimeUtc) stamp)
    {
        public string Path { get; } = path;
        public (long Length, DateTime WriteTimeUtc) Stamp { get; } = stamp;
        public Task<HashSet<string>> Names { get; } = Task.Run(() => PdfNames.Scan(path, ScannedNames));

        /// <summary>
        /// The file's bytes, if it is still as it was opened.
        /// </summary>
        /// <exception cref="IOException">It changed on disk (or can't be read).</exception>
        public byte[] Read()
        {
            var data = File.ReadAllBytes(Path);
            if (data.LongLength != Stamp.Length || DiskStamp(Path) != Stamp) throw ChangedOnDisk();
            return data;
        }

        /// <summary>Copies the file as it was opened to <paramref name="to"/>.</summary>
        /// <exception cref="IOException">It changed on disk (or can't be read).</exception>
        public void CopyTo(Stream to)
        {
            using (var from = new FileStream(Path, FileMode.Open, FileAccess.Read, FileShare.ReadWrite | FileShare.Delete, 1 << 20))
                from.CopyTo(to, 1 << 20);
            if (to.Length != Stamp.Length || DiskStamp(Path) != Stamp) throw ChangedOnDisk();
        }

        private IOException ChangedOnDisk() =>
            new($"\"{System.IO.Path.GetFileName(Path)}\" changed on disk after it was opened. Reload it to go on.");
    }

    /// <summary>The names <see cref="MayContain"/> can answer for, plus "/ObjStm" (compressed objects hide every name).</summary>
    internal static readonly string[] ScannedNames =
    [
        "/Annots", "/AcroForm", "/EmbeddedFiles", "/OCProperties", "/PageLabels", "/ByteRange", "/XFA", "/PageMode", "/PageLayout",
        "/ViewerPreferences", "/OpenAction", "/Title", "/Encrypt", "/ObjStm",
    ];

    private readonly Lock _dataGate = new();
    private byte[]? _data;          // null while a file opened in place hasn't been read
    private InPlaceFile? _inPlace;  // under _dataGate

    public string? FilePath { get; private set; }
    public string DisplayName { get; private set; }

    /// <summary>The document's bytes. For a file opened in place, read on first use (on any thread).</summary>
    /// <exception cref="IOException">A file opened in place changed on disk before it was read.</exception>
    public byte[] Data
    {
        get
        {
            if (Volatile.Read(ref _data) is { } data) return data;
            lock (_dataGate) return _data ??= _inPlace!.Read();
        }
    }

    /// <summary>True while the engine reads the file in place and its bytes haven't been read (see the class summary).</summary>
    public bool IsInPlace => _inPlace is not null && Volatile.Read(ref _data) is null;

    /// <summary>
    /// False only when the content is a file opened in place whose bytes never mention <paramref name="name"/> (one of
    /// <see cref="ScannedNames"/>, e.g. "/Annots") and keep no compressed objects: a reader of that structure would find
    /// nothing, so it needn't load and parse the file. True in every other case. Waits for the scan (a second or so on a
    /// gigabyte) if it hasn't finished.
    /// </summary>
    public bool MayContain(string name)
    {
        InPlaceFile? f;
        lock (_dataGate) f = _inPlace;
        if (f is null) return true;
        try
        {
            var names = f.Names.GetAwaiter().GetResult();
            return names.Contains(name) || (name != "/Encrypt" && names.Contains("/ObjStm"));
        }
        catch (Exception ex) when (ex is IOException or UnauthorizedAccessException)
        {
            return true;
        }
    }
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

    private sealed record EncryptionScan(object Data, bool Found);
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
            InPlaceFile? f;
            lock (_dataGate) f = _inPlace;
            object key = f ?? (object)Data;
            if (_encryptionScan is { } scan && ReferenceEquals(scan.Data, key)) return scan.Found;
            // In place: the trailer's /Encrypt is never inside a compressed object, so the file's name scan answers.
            var found = IsPdf && (f is not null ? MayContain("/Encrypt") : Data.AsSpan().IndexOf("/Encrypt"u8) >= 0);
            _encryptionScan = new EncryptionScan(key, found);
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

    private DocumentSession(string? path, string displayName, byte[]? data, string? password, InputFileTypes type, PdfEngine engine)
    {
        FilePath = path;
        DisplayName = displayName;
        _data = data;
        Password = password;
        FileType = type;
        Engine = engine;
    }

    /// <exception cref="PasswordRequiredException"/>
    public static DocumentSession Open(string path, string? password = null) => Open(path, password, InPlaceBytes);

    /// <param name="inPlaceBytes">PDFs this big or bigger open in place (<see cref="InPlaceBytes"/>; tests use less).</param>
    internal static DocumentSession Open(string path, string? password, long inPlaceBytes)
    {
        var copy = ReadDiskCopy(Path.GetFullPath(path), PdfEngine.TypeFromPath(path), password, inPlaceBytes);
        return new DocumentSession(Path.GetFullPath(path), Path.GetFileName(path), copy.Data, password, copy.Type, copy.Engine)
            { _onDisk = copy.Stamp, OpenPassword = copy.OpenPassword, _diskPassword = password, _inPlace = copy.InPlace, _inPlaceBytes = inPlaceBytes };
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
        Write(path, ContentKey);
        MarkSaved(path, _version, Password);
    }

    /// <summary>
    /// Stands for the current content: the same object until an edit, undo, redo or reload replaces it. Unlike
    /// <see cref="Data"/>, it doesn't read a file opened in place (it is that file while the content is still its own).
    /// </summary>
    public object ContentKey
    {
        get
        {
            lock (_dataGate) return _inPlace ?? (object)_data!;
        }
    }

    /// <summary>
    /// Writes <paramref name="content"/> (bytes, or a file opened in place) to <paramref name="path"/>. A file opened in
    /// place saved over itself unchanged isn't written: MuPDF holds it, and it already says what the content says.
    /// </summary>
    private static void Write(string path, object content)
    {
        switch (content)
        {
            case InPlaceFile f when string.Equals(f.Path, path, StringComparison.OrdinalIgnoreCase):
                if (DiskStamp(path) != f.Stamp) f.Read(); // throws: it changed on disk
                break;
            case InPlaceFile f:
                WriteFile(path, f.CopyTo);
                break;
            default:
                var data = (byte[])content;
                WriteFile(path, stream => stream.Write(data));
                break;
        }
    }

    /// <summary>
    /// <see cref="SaveAs"/> with the writing on a worker thread: the bytes as they are now are written, the session is
    /// updated on the calling thread afterwards. An edit committed meanwhile leaves the document dirty.
    /// </summary>
    public async Task SaveAsAsync(string path)
    {
        path = Path.GetFullPath(path);
        var (content, version, password) = (ContentKey, _version, Password);
        await Task.Run(() => Write(path, content));
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

    private static void WriteFile(string path, Action<FileStream> write)
    {
        var target = new FileInfo(path);
        if (target.Exists && target.IsReadOnly)
            throw new UnauthorizedAccessException($"\"{target.Name}\" is read-only. Save a copy under another name, or clear its read-only attribute.");

        var temp = Path.Combine(target.DirectoryName!, $".{target.Name}.{Guid.NewGuid():N}.tmp");
        try
        {
            using (var stream = new FileStream(temp, FileMode.CreateNew, FileAccess.Write, FileShare.None, 1 << 16))
            {
                write(stream);
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
    public void ReloadFromDisk() =>
        ApplyReload(ReadDiskCopy(FilePath ?? throw new InvalidOperationException("This document has not been saved to a file."), FileType, _diskPassword, _inPlaceBytes));

    /// <summary>
    /// <see cref="ReloadFromDisk"/> with the reading and parsing on a worker thread; the content is swapped on the calling
    /// thread. Returns false (nothing changed) when <paramref name="stillWanted"/> says no once the file has been read.
    /// <paramref name="password"/>: one the user gave after <see cref="PasswordRequiredException"/>.
    /// </summary>
    public async Task<bool> ReloadFromDiskAsync(Func<bool>? stillWanted = null, string? password = null)
    {
        var (path, type, inPlaceBytes) = (FilePath, FileType, _inPlaceBytes);
        password ??= _diskPassword;
        var copy = await Task.Run(() => ReadDiskCopy(path ?? throw new InvalidOperationException("This document has not been saved to a file."), type, password, inPlaceBytes));
        if (stillWanted?.Invoke() == false || path != FilePath)
        {
            copy.Engine.Dispose();
            return false;
        }
        ApplyReload(copy);
        return true;
    }

    /// <summary>A file as read from disk: its bytes, or (a big PDF) the file opened in place and not read yet.</summary>
    private sealed record DiskCopy(byte[]? Data, InPlaceFile? InPlace, InputFileTypes Type, PdfEngine Engine, (long, DateTime)? Stamp, string? Password,
        string? OpenPassword);

    private static DiskCopy ReadDiskCopy(string path, InputFileTypes type, string? password, long inPlaceBytes)
    {
        // Stamp before reading: a write that lands mid-read then shows up as a change rather than going unnoticed.
        var stamp = DiskStamp(path);
        if (type == InputFileTypes.PDF && stamp is { } s && s.Item1 >= inPlaceBytes)
        {
            var engine = PdfEngine.OpenFile(path, type, password);
            try
            {
                var file = new InPlaceFile(path, s);
                var openPassword = !string.IsNullOrEmpty(password) && PdfSecurity.IsOpenPassword(file.Read(), password) ? password : null;
                return new DiskCopy(null, file, type, engine, stamp, password, openPassword);
            }
            catch
            {
                engine.Dispose();
                throw;
            }
        }
        var data = File.ReadAllBytes(path);
        var bytesEngine = PdfEngine.Open(data, type, password);
        var open = type == InputFileTypes.PDF && PdfSecurity.IsOpenPassword(data, password) ? password : null;
        return new DiskCopy(data, null, type, bytesEngine, stamp, password, open);
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
        Swap(copy.Data, copy.Engine, version, ContentChange.Reload, copy.InPlace);
    }

    private static (long, DateTime)? DiskStamp(string path)
    {
        var info = new FileInfo(path);
        return info.Exists ? (info.Length, info.LastWriteTimeUtc) : null;
    }

    private void Swap(byte[]? data, PdfEngine engine, int version, ContentChange change, InPlaceFile? inPlace = null)
    {
        var old = Engine;
        lock (_dataGate) (_data, _inPlace) = (data, inPlace);
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
