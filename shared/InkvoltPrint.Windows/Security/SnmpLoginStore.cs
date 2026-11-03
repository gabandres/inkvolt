using InkvoltPrint.Core.Snmp;
using Windows.Security.Credentials;

namespace InkvoltPrint.Windows.Security;

/// <summary>
/// Each printer's SNMP login (<see cref="SnmpLogin"/>) in Windows Credential Manager, keyed by printer id, as the admin
/// passwords are (<see cref="CredentialStore"/>). Nothing is kept for "public". Reading never throws: a login that can't be
/// read is asked with public.
/// </summary>
public sealed class SnmpLoginStore : ISnmpLogins
{
    private const string Resource = "Inkvolt Print SNMP";

    public static SnmpLoginStore Instance { get; } = new();

    public SnmpLogin? Get(string printerId)
    {
        try
        {
            var c = new PasswordVault().Retrieve(Resource, printerId);
            c.RetrievePassword();
            return SnmpLogin.FromSecret(c.Password);
        }
        catch (Exception)
        {
            return null; // Retrieve throws when nothing is kept
        }
    }

    public void Save(string printerId, SnmpLogin login)
    {
        if (login.IsDefault) Delete(printerId);
        else new PasswordVault().Add(new PasswordCredential(Resource, printerId, login.ToSecret())); // replaces what's kept; if refused, that stays
    }

    public void Delete(string printerId)
    {
        var vault = new PasswordVault();
        try { vault.Remove(vault.Retrieve(Resource, printerId)); }
        catch (Exception) { /* nothing kept */ }
    }
}
