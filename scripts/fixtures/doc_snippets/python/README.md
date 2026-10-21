# fixture-counter

A counter, so the self-test has a published API to call.

```python
import fixture_counter

tally = fixture_counter.new("apples")
await tally.bump()
print(tally.count)
```

A later block reads the imports an earlier one made, and the values the prose has:

```python
again = fixture_counter.new("pears")
await existing.bump(by=2)
events = [...]
```

The shell shows it the same way:

```pycon
>>> from fixture_counter import new
>>> new("plums").count
0
```

<!-- doc_snippets: skip a counter-example: reset was removed in 0.2 -->
```python
tally.reset()
```

```sh
pip install fixture-counter
```
