using System.Windows;
using System.Windows.Controls;
using InkvoltPrint.Core;
using InkvoltPrint.Core.Snmp;

namespace InkvoltPrint.App.Views;

/// <summary>
/// The SNMP access fields (Add a printer's and the printer's menu's): a community, or an SNMPv3 user and its two passphrases,
/// which is an Inkvolt Pro feature (<see cref="Pro.Allows"/>). <see cref="Read"/> says what was entered, or why it can't be used.
/// </summary>
public partial class SnmpAccessFields : UserControl
{
    public SnmpAccessFields()
    {
        InitializeComponent();
        // The protocols' own names (the same in every language), in the enums' order: an item's index is its value.
        AuthProtocol.ItemsSource = Enum.GetValues<SnmpAuth>().Select(Usm.Name).ToList();
        PrivProtocol.ItemsSource = Enum.GetValues<SnmpPriv>().Select(Usm.Name).ToList();
        (AuthProtocol.SelectedIndex, PrivProtocol.SelectedIndex) = (0, 0);
        Kind_Changed(this, new RoutedEventArgs());
    }

    /// <summary>Shows <paramref name="current"/> (a community, public as blank, or a v3 user with its passphrases masked).</summary>
    public void Show(SnmpLogin current)
    {
        if (current.User is { } user)
        {
            UseV3.IsChecked = true;
            UserBox.Text = user.Name;
            AuthBox.Password = user.AuthPassphrase;
            PrivBox.Password = user.PrivPassphrase;
            AuthProtocol.SelectedIndex = (int)user.Auth;
            PrivProtocol.SelectedIndex = (int)user.Priv;
        }
        else
        {
            UseCommunity.IsChecked = true;
            CommunityBox.Text = current.IsDefault ? "" : current.Community;
        }
        Error.Visibility = Visibility.Collapsed;
    }

    /// <summary>The first field to type in.</summary>
    public void FocusFirst()
    {
        var box = UseV3.IsChecked == true ? (Control)UserBox : CommunityBox;
        box.Focus();
        if (box is TextBox t) t.SelectAll();
    }

    /// <summary>The login entered, or null with the reason shown (and, for SNMPv3 without Inkvolt Pro, its window opened).</summary>
    public SnmpLogin? Read()
    {
        string? error;
        SnmpLogin? login;
        if (UseV3.IsChecked == true)
        {
            login = SnmpLogin.ForUser(UserBox.Text, AuthBox.Password, PrivBox.Password, out error, Auth, Priv);
            if (login is not null && !Pro.Allows(ProFeature.SnmpV3))
            {
                (login, error) = (null, Pro.Locked(ProFeature.SnmpV3));
                ProWindow.Open(Window.GetWindow(this), ProFeature.SnmpV3);
            }
        }
        else login = SnmpLogin.ForCommunity(CommunityBox.Text, out error);
        Error.Text = error;
        Error.Visibility = error is null ? Visibility.Collapsed : Visibility.Visible;
        return login;
    }

    /// <summary>Something was typed or the kind changed (SNMP access…'s Save anyway then goes back to Save).</summary>
    public event Action? Edited;

    private void Kind_Changed(object sender, RoutedEventArgs e)
    {
        if (CommunityPanel is null || V3Panel is null) return; // while loading
        Edited?.Invoke();
        var v3 = UseV3.IsChecked == true;
        CommunityPanel.Visibility = v3 ? Visibility.Collapsed : Visibility.Visible;
        V3Panel.Visibility = v3 ? Visibility.Visible : Visibility.Collapsed;
        var locked = !Pro.Allows(ProFeature.SnmpV3);
        ProNote.Text = locked ? string.Format(Strings.Snmp_ProNote, Pro.Locked(ProFeature.SnmpV3)) : "";
        ProNote.Visibility = locked ? Visibility.Visible : Visibility.Collapsed;
        Error.Visibility = Visibility.Collapsed;
    }

    private void Field_Changed(object sender, RoutedEventArgs e)
    {
        Error.Visibility = Visibility.Collapsed;
        Edited?.Invoke();
    }

    /// <summary>The protocols chosen: the combo boxes list <see cref="SnmpAuth"/> and <see cref="SnmpPriv"/> in their order.</summary>
    private SnmpAuth Auth => Enum.IsDefined((SnmpAuth)AuthProtocol.SelectedIndex) ? (SnmpAuth)AuthProtocol.SelectedIndex : SnmpAuth.Sha256;

    private SnmpPriv Priv => Enum.IsDefined((SnmpPriv)PrivProtocol.SelectedIndex) ? (SnmpPriv)PrivProtocol.SelectedIndex : SnmpPriv.Aes128;

    private void Protocol_Changed(object sender, SelectionChangedEventArgs e)
    {
        if (WeakNote is null || AuthProtocol is null || PrivProtocol is null) return; // while loading
        WeakNote.Visibility = Auth != SnmpAuth.Sha256 || Priv == SnmpPriv.Des ? Visibility.Visible : Visibility.Collapsed;
        Field_Changed(sender, e);
    }
}
