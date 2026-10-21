# fixture_counter

A counter, so the self-test has a published API to call.

```csharp
using FixtureCounter;

var tally = Tally.New("apples");
tally.Bump();
Console.WriteLine(tally.Count);
```

The prose names a realm and the code does not: a free name is the reader's, and
so is the member it calls. The same block waits, which needs the fragment to
have a method around it that can wait:

```csharp
var opened = await Tally.OpenAsync("apples");
Console.WriteLine(opened.Count + realm.Size);
```

A block of your own types is a file, and is held to the compiler entirely:

```csharp
public sealed class Counter
{
    private int count;

    public int Bump() => ++count;
}
```

<!-- doc_snippets: skip a counter-example: the call this paragraph warns against -->
```csharp
Tally.Reset();
```

Configuration is not code, and a block in another language is not read:

```yaml
counter:
  label: apples
```
