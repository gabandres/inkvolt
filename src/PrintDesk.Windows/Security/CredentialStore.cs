using Windows.Security.Credentials;

namespace PrintDesk.Windows.Security;

/// <summary>Printer admin passwords in Windows Credential Manager, keyed by printer UUID.</summary>
public static class CredentialStore
{
    private const string Resource = "PrintDesk printer admin";

    public static string? Get(string printerUuid)
    {
        try
        {
            var c = new PasswordVault().Retrieve(Resource, printerUuid);
            c.RetrievePassword();
            return c.Password;
        }
        catch (Exception)
        {
            return null; // Retrieve throws when nothing is stored
        }
    }

    public static void Save(string printerUuid, string password)
    {
        Delete(printerUuid);
        new PasswordVault().Add(new PasswordCredential(Resource, printerUuid, password));
    }

    /// <summary>Moves a saved password to a new id; never overwrites a password already saved there. Never throws.</summary>
    public static void Rename(string oldId, string newId)
    {
        try
        {
            if (Get(oldId) is not { } pw) return;
            if (Get(newId) is null) Save(newId, pw);
            Delete(oldId);
        }
        catch (Exception)
        {
            // Credential Manager unavailable: the user will simply be asked for the password again.
        }
    }

    public static void Delete(string printerUuid)
    {
        var vault = new PasswordVault();
        try { vault.Remove(vault.Retrieve(Resource, printerUuid)); }
        catch (Exception) { /* nothing stored */ }
    }
}
