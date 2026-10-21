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

A module may carry a macro of its own. epp expands it, so the check reads the
directive as the form it is:

```erlang
-module(step_counter).
-export([next/1]).

-define(STEP, 1).

next(T) -> ?STEP + fixture_counter:count(fixture_counter:bump(T)).
```

A record's fields are read with a full stop, and the header supplies the record:

```erlang
Tally2 = fixture_counter:new(plums),
0 = Tally2#tally.count.
```

This guide runs:

<!-- doc_snippets: run -->
```erlang
T = double_counter:bump_twice(fixture_counter:new(pears)),
2 = fixture_counter:count(T).
```
