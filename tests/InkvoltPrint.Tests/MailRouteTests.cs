using InkvoltPrint.Core.Presets;

namespace InkvoltPrint.Tests;

public class MailRouteTests
{
    // What Windows 11 reports with the new Outlook as the default mail app: an AppX ProgId whose Application key names the package.
    private const string NewOutlookProgId = "AppXbx2ce4vcxjdhff3d1ms66qqzk12zn827";
    private const string NewOutlookAppId = "Microsoft.OutlookForWindows_8wekyb3d8bbwe!Microsoft.OutlookforWindows";

    [Fact]
    public void New_outlook_as_the_mail_app_skips_mapi_even_with_classic_outlook_registered() =>
        Assert.Equal(MailRouteKind.FolderAndMailto,
            MailRoute.Choose(new MailSetup("Microsoft Outlook", NewOutlookProgId, NewOutlookAppId, OutlookHasProfile: true)).Kind);

    [Fact]
    public void Classic_outlook_without_a_profile_skips_mapi()
    {
        var (kind, why) = MailRoute.Choose(new MailSetup("Microsoft Outlook", "Outlook.URL.mailto.15", null, OutlookHasProfile: false));

        Assert.Equal(MailRouteKind.FolderAndMailto, kind);
        Assert.Contains("profile", why);
    }

    [Fact]
    public void Classic_outlook_with_a_profile_attaches() =>
        Assert.Equal(MailRouteKind.Mapi, MailRoute.Choose(new MailSetup("Microsoft Outlook", "Outlook.URL.mailto.15", null, true)).Kind);

    [Fact]
    public void Thunderbird_attaches_whatever_outlook_has() =>
        Assert.Equal(MailRouteKind.Mapi, MailRoute.Choose(new MailSetup("Mozilla Thunderbird", "Thunderbird.Url.mailto", null, false)).Kind);

    [Theory]
    [InlineData(null)]
    [InlineData("")]
    [InlineData("  ")]
    public void No_mapi_client_uses_mailto(string? client) =>
        Assert.Equal(MailRouteKind.FolderAndMailto, MailRoute.Choose(new MailSetup(client, null, null, null)).Kind);

    [Fact]
    public void Mailto_carries_the_subject_and_a_reminder_of_the_file()
    {
        var uri = MailRoute.MailtoUri("Receipt 2026-10-24", ["Receipt 2026-10-24 001.pdf"]);

        Assert.Equal("mailto:?subject=Receipt%202026-10-24&body=Attached%3A%20Receipt%202026-10-24%20001.pdf", uri);
        Assert.Equal("Attached: a.jpg, b.jpg", MailRoute.AttachLine(["a.jpg", "b.jpg"]));
    }
}
