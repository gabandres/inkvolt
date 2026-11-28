using InkvoltPdf.Core;

namespace InkvoltPdf.Tests;

/// <summary>Next Comment / Previous Comment (View menu, the Mac's Go menu; <see cref="Annotations.StepComment"/>).</summary>
public class CommentNavigationTests
{
    [Fact]
    public void NextCommentStartsAtTheFirstAndWrapsAround()
    {
        Assert.Equal(0, Annotations.StepComment(3, -1, 1));
        Assert.Equal(1, Annotations.StepComment(3, 0, 1));
        Assert.Equal(0, Annotations.StepComment(3, 2, 1));
    }

    [Fact]
    public void PreviousCommentStartsAtTheLastAndWrapsAround()
    {
        Assert.Equal(2, Annotations.StepComment(3, -1, -1));
        Assert.Equal(2, Annotations.StepComment(3, 0, -1));
        Assert.Equal(0, Annotations.StepComment(3, 1, -1));
    }

    [Fact]
    public void NoCommentsOrOneNoLongerListed()
    {
        Assert.Equal(-1, Annotations.StepComment(0, -1, 1));
        Assert.Equal(0, Annotations.StepComment(1, 0, 1));
        Assert.Equal(0, Annotations.StepComment(2, 7, 1));
        Assert.Equal(1, Annotations.StepComment(2, 7, -1));
        Assert.Equal(1, Annotations.StepComment(2, 0, int.MaxValue));
    }
}
