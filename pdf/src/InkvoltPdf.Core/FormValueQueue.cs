namespace InkvoltPdf.Core;

/// <summary>What the tab does about a batch of field values once its edit has ended (<see cref="FormValueQueue.Finished"/>).</summary>
public enum FormBatchEnd
{
    /// <summary>Written, or put back to try again: go on with what is queued.</summary>
    GoOn,
    /// <summary>Nothing was written (its form refused them): those fields show the document's values again; go on with what is queued.</summary>
    ShowDocumentValues,
    /// <summary>The person declined, or the write failed: nothing queued stays, and every field shows the document's values.</summary>
    Stop,
}

/// <summary>
/// The values typed into form fields and not yet written, one batch at a time (the newest value of each field). A value typed
/// while a batch is being written stays queued whatever that batch comes to, unless the whole edit was declined or failed: a
/// value one field's script refuses says nothing about the next field's, typed just before the save.
/// </summary>
public sealed class FormValueQueue
{
    private readonly Dictionary<string, string> _values = [];

    public int Count => _values.Count;

    public void Set(string field, string value) => _values[field] = value;

    public void Clear() => _values.Clear();

    /// <summary>What is queued, as the next batch; the queue is empty after it.</summary>
    public IReadOnlyDictionary<string, string> Take()
    {
        var batch = new Dictionary<string, string>(_values);
        _values.Clear();
        return batch;
    }

    /// <summary>Takes in how the edit of <paramref name="batch"/> ended, and says what to do next.</summary>
    public FormBatchEnd Finished(IReadOnlyDictionary<string, string> batch, EditOutcome outcome)
    {
        switch (outcome)
        {
            case EditOutcome.Done:
                return FormBatchEnd.GoOn;
            case EditOutcome.NoChange:
                return FormBatchEnd.ShowDocumentValues;
            case EditOutcome.Busy:
                // Another edit (or its question) got the document first: back in the queue, newer values typed meanwhile win.
                foreach (var (field, value) in batch) _values.TryAdd(field, value);
                return FormBatchEnd.GoOn;
            default:
                _values.Clear();
                return FormBatchEnd.Stop;
        }
    }
}
