# Extending

A guide is read the same way as the README, at any depth below the package.

```csharp
using FixtureCounter;

var tally = Tally.New("pears");
var next = tally.Bump();
Console.WriteLine(next);

// A name a block of alternatives binds twice is the doc's own shape, not an
// error: the second `var` is how the prose says "or this".
if (next > 0)
{
    var note = "counting";
    Console.WriteLine(note);
}
else
{
    var note = "idle";
    Console.WriteLine(note);
}
```
