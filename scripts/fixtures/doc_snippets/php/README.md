# fixture_counter

A counter, so the self-test has a published API to call.

```php
use FixtureCounter\Tally;

$tally = Tally::new('apples');
$tally->bump();
echo $tally->count(), "\n";
```

The prose names a realm and the code does not: a free variable is the reader's,
and so is a helper this package never heard of. The block after this one leaves
its `use` out, and is read with this one carried in, as a reader that far down
the page has it:

```php
$answer = $pool->call($realm, 'mcl-echo/echo', 'hello');
echo my_own_helper($answer), "\n";
```

A block of your own types declares a class:

```php
final class Counter
{
    private int $count = 0;

    public function bump(): int
    {
        return ++$this->count;
    }
}
```

<!-- doc_snippets: skip a counter-example: the call this paragraph warns against -->
```php
Tally::reset();
```

Configuration is not code, and a block in another language is not read:

```yaml
counter:
  label: apples
```
