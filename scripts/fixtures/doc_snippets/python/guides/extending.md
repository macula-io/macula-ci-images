# Extending the counter

A function of your own:

```python
from fixture_counter import Tally


async def bump_twice(tally: Tally) -> int:
    await tally.bump()
    await tally.bump()
    return tally.count
```
