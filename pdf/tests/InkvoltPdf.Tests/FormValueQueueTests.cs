using InkvoltPdf.Core;

namespace InkvoltPdf.Tests;

/// <summary>Values typed while an earlier batch is being written: what becomes of them, by how that batch ended.</summary>
public class FormValueQueueTests
{
    private static (FormValueQueue Queue, IReadOnlyDictionary<string, string> Batch) WithNewerValue()
    {
        var queue = new FormValueQueue();
        queue.Set("first", "1");
        var batch = queue.Take();
        Assert.Equal(0, queue.Count);
        queue.Set("second", "2"); // typed, and Ctrl+S pressed, while the first is being written
        return (queue, batch);
    }

    [Fact]
    public void AValueTypedWhileARefusedOneIsWrittenIsStillWritten()
    {
        var (queue, batch) = WithNewerValue();
        Assert.Equal(FormBatchEnd.ShowDocumentValues, queue.Finished(batch, EditOutcome.NoChange));
        Assert.Equal("2", queue.Take()["second"]);
    }

    [Fact]
    public void AWrittenBatchLeavesTheNewerValue()
    {
        var (queue, batch) = WithNewerValue();
        Assert.Equal(FormBatchEnd.GoOn, queue.Finished(batch, EditOutcome.Done));
        Assert.Equal(["second"], queue.Take().Keys);
    }

    [Fact]
    public void ABusyDocumentPutsTheBatchBackAndANewerValueWins()
    {
        var queue = new FormValueQueue();
        queue.Set("a", "old");
        queue.Set("b", "kept");
        var batch = queue.Take();
        queue.Set("a", "new");
        Assert.Equal(FormBatchEnd.GoOn, queue.Finished(batch, EditOutcome.Busy));
        var next = queue.Take();
        Assert.Equal("new", next["a"]);
        Assert.Equal("kept", next["b"]);
    }

    [Theory]
    [InlineData(EditOutcome.Declined)]
    [InlineData(EditOutcome.Failed)]
    public void ADeclinedOrFailedEditDropsWhatIsQueued(EditOutcome outcome)
    {
        var (queue, batch) = WithNewerValue();
        Assert.Equal(FormBatchEnd.Stop, queue.Finished(batch, outcome));
        Assert.Equal(0, queue.Count);
    }
}
