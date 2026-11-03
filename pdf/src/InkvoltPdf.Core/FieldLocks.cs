namespace InkvoltPdf.Core;

/// <summary>The Sign dialog's "Lock form fields" choice when certifying: its entries, the line under it, and the lock it makes.</summary>
public static class FieldLocks
{
    public static readonly IReadOnlyList<string> Choices =
        ["Don't lock fields", "Lock all fields", "Lock these fields", "Lock all fields but these"];

    /// <summary>What the chosen entry does, in a line.</summary>
    public static string Note(int choice) => choice switch
    {
        1 => "No field can be changed after you certify without it showing as not allowed.",
        2 => "Only the fields you choose are locked; the others can still be filled in.",
        3 => "The fields you choose stay open for others to fill in; the rest are locked.",
        _ => "Fields can be filled in after you certify, as the certification allows.",
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
