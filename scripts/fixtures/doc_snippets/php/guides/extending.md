# Extending

A guide is read the same way as the README, at any depth below the package.

```php
use FixtureCounter\Tally;

$tally = Tally::new('pears');
$next = $tally->bump();
echo $next, "\n";
```
