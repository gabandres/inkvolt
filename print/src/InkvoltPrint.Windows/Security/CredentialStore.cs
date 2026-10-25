using Windows.Security.Credentials;

namespace InkvoltPrint.Windows.Security;

/// <summary>Printer admin passwords in Windows Credential Manager, keyed by printer UUID.</summary>
public static class CredentialStore
{
    private const string Resource = "Inkvolt Print printer admin";

    /// <summary>Where passwords were saved before the Inkvolt rename; moved to <see cref="Resource"/> when first read.</summary>
    private const string LegacyResource = "PrintDesk printer admin";

    public static string? Get(string printerUuid) => Read(Resource, printerUuid) ?? AdoptLegacy(printerUuid);

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
        Remove(Resource, printerUuid);
        Remove(LegacyResource, printerUuid);
    }

    private static string? Read(string resource, string printerUuid)
    {
        try
        {
            var c = new PasswordVault().Retrieve(resource, printerUuid);
            c.RetrievePassword();
            return c.Password;
        }
        catch (Exception)
        {
            return null; // Retrieve throws when nothing is stored
        }
    }

    /// <summary>A password saved under the pre-rename resource: re-saved under the new one, then removed. Never throws.</summary>
    private static string? AdoptLegacy(string printerUuid)
    {
        if (Read(LegacyResource, printerUuid) is not { } pw) return null;
        try
        {
            new PasswordVault().Add(new PasswordCredential(Resource, printerUuid, pw));
            Remove(LegacyResource, printerUuid);
        }
        catch (Exception)
        {
            // Couldn't re-save: keep using the old entry; the move is tried again next time.
        }
        return pw;
    }

    private static void Remove(string resource, string printerUuid)
    {
        var vault = new PasswordVault();
        try { vault.Remove(vault.Retrieve(resource, printerUuid)); }
        catch (Exception) { /* nothing stored */ }
    }
}
