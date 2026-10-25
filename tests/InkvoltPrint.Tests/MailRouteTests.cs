using InkvoltPrint.Core.Presets;

namespace InkvoltPrint.Tests;

public class MailRouteTests
{
    [Fact]
    public void Classic_outlook_without_a_profile_skips_mapi()
    {
        var (kind, why) = MailRoute.Choose(new MailSetup("Microsoft Outlook", OutlookHasProfile: false));

        Assert.Equal(MailRouteKind.FolderAndMailto, kind);
        Assert.Contains("profile", why);
    }

    [Fact]
    public void Classic_outlook_with_a_profile_attaches() =>
        Assert.Equal(MailRouteKind.Mapi, MailRoute.Choose(new MailSetup("Microsoft Outlook", true)).Kind);

    [Fact]
    public void Classic_outlook_whose_profiles_couldnt_be_read_is_tried() =>
        Assert.Equal(MailRouteKind.Mapi, MailRoute.Choose(new MailSetup("Microsoft Outlook", null)).Kind);

    [Fact]
    public void Thunderbird_attaches_whatever_handles_mailto_and_whatever_outlook_has() =>
        // e.g. the new Outlook as the default mail app and Thunderbird as the MAPI client: MAPI works.
        Assert.Equal(MailRouteKind.Mapi, MailRoute.Choose(new MailSetup("Mozilla Thunderbird", false)).Kind);

    [Theory]
    [InlineData(null)]
    [InlineData("")]
    [InlineData("  ")]
    public void No_mapi_client_uses_mailto(string? client) =>
        Assert.Equal(MailRouteKind.FolderAndMailto, MailRoute.Choose(new MailSetup(client, null)).Kind);

    [Fact]
    public void Mailto_carries_the_subject_and_a_reminder_of_the_file()
    {
        var uri = MailRoute.MailtoUri("Receipt 2026-10-24", ["Receipt 2026-10-24 001.pdf"]);

        Assert.Equal("mailto:?subject=Receipt%202026-10-24&body=Attached%3A%20Receipt%202026-10-24%20001.pdf", uri);
        Assert.Equal("Attached: a.jpg, b.jpg", MailRoute.AttachLine(["a.jpg", "b.jpg"]));
    }
}
