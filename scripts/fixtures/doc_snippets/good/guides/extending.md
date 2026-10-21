# Extending the counter

A module of your own, calling the package:

```erlang
-module(double_counter).
-export([bump_twice/1]).

bump_twice(T) -> fixture_counter:bump(fixture_counter:bump(T)).
```

Functions and a spec without a module are compiled in one of their own:

```erlang
-spec total([term()]) -> non_neg_integer().
total(Tallies) -> lists:sum([fixture_counter:count(T) || T <- Tallies]).
```

This guide runs:

<!-- doc_snippets: run -->
```erlang
T = double_counter:bump_twice(fixture_counter:new(pears)),
2 = fixture_counter:count(T).
```
