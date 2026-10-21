-module(fixture_counter).
-include("fixture_counter.hrl").
-export([new/1, bump/1, count/1]).

new(Name) -> #tally{name = Name}.

bump(#tally{count = N} = T) -> T#tally{count = N + 1}.

count(#tally{count = N}) -> N.
