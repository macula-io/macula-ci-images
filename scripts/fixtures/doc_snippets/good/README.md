# fixture_counter

A counter, so the self-test has a published API to call.

```erlang
T0 = fixture_counter:new(apples),
T1 = fixture_counter:bump(T0).
```

The shell shows it the same way; the output lines are not code:

```erlang
1> T2 = fixture_counter:bump(T1).
{tally,apples,2}
2> fixture_counter:count(
2>     T2).
2
3> rr("include/fixture_counter.hrl").
[tally]
```

A record from the package's header needs no include in a doc:

```erlang
#tally{count = 2} = T2.
```

<!-- doc_snippets: skip a counter-example: the call this paragraph warns against -->
```erlang
fixture_counter:reset(T2).
```

Configuration is a term, and a term is an expression:

```erl
{deps, [{fixture_counter, "~> 0.1"}]}.
```

```sh
rebar3 compile
```
