using Windows.Security.Credentials;

namespace InkvoltPrint.Windows.Security;

/// <summary>
/// The passwords scan presets put on their PDFs (roadmap 4.18), in Windows Credential Manager keyed by the preset's id: never in
/// the presets' file. Every call is safe to make when Credential Manager is unavailable (nothing kept: the save asks again).
/// </summary>
public static class PresetPasswordStore
{
    private const string Resource = "Inkvolt Print scan preset password";

    public static string? Get(string presetId)
    {
        try
        {
            var c = new PasswordVault().Retrieve(Resource, presetId);
            c.RetrievePassword();
            return c.Password;
        }
        catch (Exception)
        {
            return null; // Retrieve throws when nothing is stored
        }
    }

    public static void Save(string presetId, string password)
    {
        Delete(presetId);
        try { new PasswordVault().Add(new PasswordCredential(Resource, presetId, password)); }
        catch (Exception) { /* not kept: asked again next time */ }
    }

    public static void Delete(string presetId)
    {
        try
        {
            var vault = new PasswordVault();
            vault.Remove(vault.Retrieve(Resource, presetId));
        }
        catch (Exception) { /* nothing stored */ }
    }
}
