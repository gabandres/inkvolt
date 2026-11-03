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
            login = SnmpLogin.ForUser(UserBox.Text, AuthBox.Password, PrivBox.Password, out error);
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

    private void Kind_Changed(object sender, RoutedEventArgs e)
    {
        if (CommunityPanel is null || V3Panel is null) return; // while loading
        var v3 = UseV3.IsChecked == true;
        CommunityPanel.Visibility = v3 ? Visibility.Collapsed : Visibility.Visible;
        V3Panel.Visibility = v3 ? Visibility.Visible : Visibility.Collapsed;
        var locked = !Pro.Allows(ProFeature.SnmpV3);
        ProNote.Text = locked ? $"{Pro.Locked(ProFeature.SnmpV3)} Help › Inkvolt Pro… enters a key." : "";
        ProNote.Visibility = locked ? Visibility.Visible : Visibility.Collapsed;
        Error.Visibility = Visibility.Collapsed;
    }

    private void Field_Changed(object sender, RoutedEventArgs e) => Error.Visibility = Visibility.Collapsed;
}
