namespace InkvoltPdf.Core;

/// <summary>The Sign dialog's "Lock form fields" choice when certifying: its entries, the line under it, and the lock it makes.</summary>
public static class FieldLocks
{
    public static IReadOnlyList<string> Choices =>
        [PdfStrings.Form_LockNone, PdfStrings.Form_LockAll, PdfStrings.Form_LockThese, PdfStrings.Form_LockAllBut];

    /// <summary>What the chosen entry does, in a line.</summary>
    public static string Note(int choice) => choice switch
    {
        1 => PdfStrings.Form_LockAllNote,
        2 => PdfStrings.Form_LockTheseNote,
        3 => PdfStrings.Form_LockAllButNote,
        _ => PdfStrings.Form_LockNoneNote,
    };

    /// <summary>The lock for entry <paramref name="choice"/> with the fields picked in the list; null for "Don't lock fields".</summary>
    public static FieldLock? From(int choice, IReadOnlyList<string> picked) => choice switch
    {
        1 => FieldLock.AllFields,
        2 => new FieldLock(FieldLockAction.Include, picked),
        3 => new FieldLock(FieldLockAction.Exclude, picked),
        _ => null,
    };
}
