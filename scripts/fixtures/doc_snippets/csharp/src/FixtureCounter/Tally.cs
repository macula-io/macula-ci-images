namespace FixtureCounter;

/// <summary>A tally of one kind of thing, so the docs have something to count.</summary>
public sealed class Tally
{
    private int count;

    public Tally(string label) => Label = label;

    public string Label { get; }

    public int Count => count;

    /// <summary>Count one more, and answer the new count.</summary>
    public int Bump() => ++count;

    /// <summary>A new tally, in the shape a quick start opens with.</summary>
    public static Tally New(string label) => new(label);

    /// <summary>The same, opened off the caller's thread.</summary>
    public static async Task<Tally> OpenAsync(string label)
    {
        await Task.Yield();
        return new Tally(label);
    }

    /// <summary>
    /// The call the docs warn against: it drops the count and every holder of
    /// the tally keeps a stale one. Here it is a counter-example, not a service.
    /// </summary>
    public static void Reset() => throw new NotSupportedException("reset drops counts");
}
