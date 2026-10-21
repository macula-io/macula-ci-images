#!/usr/bin/env escript
%% -*- erlang -*-
%%! -noshell
%%
%% Every Erlang code block a repository publishes compiles against its own code,
%% calls only functions that exist, and runs where the doc says it runs.
%%
%% Usage: doc_snippets_erlang.escript [--timeout SECONDS] ROOT
%%
%% ROOT is a rebar3 checkout that has been compiled (rebar3 compile), so its own
%% applications and its dependencies are under ROOT/_build/default/lib. The docs
%% read are the ones a package ships: README*.md and guides/**.md at any depth,
%% and docs/**.md without design records, plans, reports, backlogs or registers.
%% The blocks read are the ones fenced erlang or erl.
%%
%% A block is one of three things:
%%
%%   a module      it has a -module attribute: compiled as it stands, and loaded
%%   forms         functions, records, types, specs without a module: compiled
%%                 inside a module of their own
%%   a session     expressions, or a shell session (1> prompts, output lines
%%                 ignored): each block is the body of a function whose
%%                 parameters are the variables it uses and does not bind, so
%%                 a fragment that uses a Client the prose has made is checked
%%                 for its calls and syntax as it stands. A run marker also
%%                 compiles the session blocks up to it strictly, in order as
%%                 one body, and executes them: there a variable must be bound
%%                 by an earlier block
%%
%% Every remote call with a literal module and function must reach an exported
%% function of a module on the code path, so an example that calls an API that
%% is gone fails here even though the compiler accepts it. Records a session or a
%% forms block uses are taken from the header that defines them, in the repo's
%% include/ directories or its dependencies'. A reader who pastes such a block
%% into a shell still needs rr/1 or an -include_lib: the doc should say which.
%% A module block is compiled as it stands, so it carries its own includes.
%%
%% Markers, an HTML comment on the line before the fence:
%%
%%   <!-- doc_snippets: skip <reason> -->   not checked; the reason is required
%%   <!-- doc_snippets: run -->              the doc's session blocks up to and
%%                                           including this one are executed, and
%%                                           an exception or a timeout fails
%%
%% Exit 0 when every block passes, 1 when any fails (each failure printed as
%% path:line: message), 2 when the check cannot run (no compiled checkout).
%% Warnings are not failures: an unused variable in an example is not wrong.

-mode(compile).

-define(SKIP_DIRS, ["_build", "deps", ".git", "node_modules", "vendor", "target",
                    ".elixir_ls", "_checkouts", "dist", ".venv"]).
-define(SHIPPED_DOCS,
        "^(?!(?:.*/)?(?:fixtures|testdata|vectors?)/)"
        "(?!docs/(?:design|adr|adrs|decisions|plans?|reports?|research)/)"
        "(?!docs/(?:.*/)?[^/]*(?:backlog|register)[^/]*$)"
        "(?:(?:.*/)?README[^/]*\\.md|(?:.*/)?guides/.+\\.md|docs/.+\\.md)$").
-define(MARKER, "^\\s*<!--\\s*doc_snippets:\\s*(\\S+)\\s*(.*?)\\s*-->\\s*$").
-define(FENCE, "^(\\s*)(`{3,}|~{3,})\\s*([^`\\s]*)").
-define(PROMPT, "^\\s*\\d+>\\s?(.*)$").
%% What the shell offers that a module does not: dropped from a session, since
%% they configure the shell rather than say anything about the code.
-define(SHELL_COMMANDS, [b, c, e, f, h, help, i, l, m, q, rd, rf, rl, rp, rr, v]).

main(Args) ->
    case options(Args, #{timeout => 120}) of
        {ok, #{root := Root} = Opts} -> halt(run(filename:absname(Root), Opts));
        error ->
            io:format(standard_error,
                      "usage: doc_snippets_erlang.escript [--timeout SECONDS] ROOT~n", []),
            halt(2)
    end.

options(["--timeout", Seconds | Rest], Opts) ->
    case string:to_integer(Seconds) of
        {N, ""} when N > 0 -> options(Rest, Opts#{timeout => N});
        _ -> error
    end;
options([Root], Opts) -> {ok, Opts#{root => Root}};
options(_, _) -> error.

run(Root, Opts) ->
    Ebins = filelib:wildcard(filename:join([Root, "_build", "default", "lib", "*", "ebin"])),
    case Ebins of
        [] ->
            io:format(standard_error, "doc_snippets: nothing compiled under ~s/_build/default/lib; "
                      "run rebar3 compile first~n", [Root]),
            2;
        _ ->
            ok = code:add_pathsa(Ebins),
            Work = work_dir(),
            Headers = record_headers(Root),
            Docs = docs(Root),
            Failures = lists:append([check_doc(Root, Doc, Headers, Work, Opts) || Doc <- Docs]),
            [io:format("~s:~p: ~ts~n", [Path, Line, Message])
             || {Path, Line, Message} <- Failures],
            io:format(standard_error, "doc_snippets: ~p failure(s) in ~p doc(s)~n",
                      [length(Failures), length(Docs)]),
            case Failures of [] -> 0; _ -> 1 end
    end.

work_dir() ->
    Base = os:getenv("RUNNER_TEMP", filename:basedir(user_cache, "doc_snippets")),
    Dir = filename:join(Base, "doc_snippets_" ++ os:getpid()),
    ok = filelib:ensure_path(Dir),
    Dir.

%% --------------------------------------------------------------------------
%% Which docs.

docs(Root) ->
    lists:sort([Rel || Rel <- walk(Root, ""),
                       re:run(Rel, ?SHIPPED_DOCS, [caseless, {capture, none}, unicode]) =:= match]).

walk(Root, Rel) ->
    Dir = filename:join(Root, Rel),
    {ok, Names} = file:list_dir(Dir),
    lists:append([entry(Root, join(Rel, Name)) || Name <- lists:sort(Names),
                                                  not lists:member(Name, ?SKIP_DIRS)]).

entry(Root, Rel) ->
    Path = filename:join(Root, Rel),
    case filelib:is_dir(Path) of
        true -> walk(Root, Rel);
        false -> [Rel]
    end.

join("", Name) -> Name;
join(Rel, Name) -> Rel ++ "/" ++ Name.

%% Record name -> the header that defines it. The repo's own headers win over a
%% dependency's, so a guide sees the record the repo itself compiles with.
record_headers(Root) ->
    Own = filelib:wildcard(filename:join(Root, "include/*.hrl"))
        ++ filelib:wildcard(filename:join(Root, "apps/*/include/*.hrl")),
    Deps = filelib:wildcard(filename:join([Root, "_build", "default", "lib", "*", "include", "*.hrl"])),
    lists:foldl(fun(Header, Acc) ->
                        {ok, Text} = file:read_file(Header),
                        Names = re:run(Text, "-record\\(\\s*'?([a-z][A-Za-z0-9_@]*)'?",
                                       [global, {capture, all_but_first, list}]),
                        lists:foldl(fun([Name], In) -> maps:put(list_to_atom(Name), Header, In) end,
                                    Acc, case Names of nomatch -> []; {match, M} -> M end)
                end, #{}, Deps ++ Own).

%% --------------------------------------------------------------------------
%% Markdown.

%% Every fenced block, as #{line, word, marker, body}: line is the fence's own
%% line, body the content lines as {Line, Text} with the fence's indent removed.
blocks(Text) ->
    Split = string:split(Text, "\n", all),
    blocks(lists:zip(lists:seq(1, length(Split)), Split), none, []).

blocks([], _, Acc) -> lists:reverse(Acc);
blocks([{N, Line} | Rest], Previous, Acc) ->
    case re:run(Line, ?FENCE, [{capture, all_but_first, list}, unicode]) of
        {match, [Indent, Fence, Info]} ->
            {Body, After} = fence_body(Rest, Fence, length(Indent), []),
            [Word | _] = string:split(string:trim(string:lowercase(Info), both, "{}."), ","),
            Block = #{line => N, word => Word, marker => marker(Previous), body => Body},
            blocks(After, none, [Block | Acc]);
        nomatch ->
            blocks(Rest, case string:trim(Line) of "" -> Previous; _ -> Line end, Acc)
    end.

fence_body([], _, _, Acc) -> {lists:reverse(Acc), []};
fence_body([{N, Line} | Rest], Fence, Indent, Acc) ->
    Trimmed = string:trim(Line),
    Char = hd(Fence),
    case length(Trimmed) >= length(Fence) andalso lists:all(fun(C) -> C =:= Char end, Trimmed) of
        true -> {lists:reverse(Acc), Rest};
        false -> fence_body(Rest, Fence, Indent, [{N, dedent(Line, Indent)} | Acc])
    end.

dedent([$\s | Rest], N) when N > 0 -> dedent(Rest, N - 1);
dedent(Line, _) -> Line.

marker(none) -> none;
marker(Line) ->
    case re:run(Line, ?MARKER, [{capture, all_but_first, list}, unicode]) of
        {match, [Word, Reason]} -> {Word, Reason};
        nomatch -> none
    end.

%% --------------------------------------------------------------------------
%% One doc.

check_doc(Root, Doc, Headers, Work, Opts) ->
    {ok, Bin} = file:read_file(filename:join(Root, Doc)),
    Erlang = [B || #{word := W} = B <- blocks(unicode:characters_to_list(Bin)),
                   W =:= "erlang" orelse W =:= "erl"],
    {Marked, Checked} = lists:foldr(fun(B, {F, C}) -> marked(Doc, B, F, C) end, {[], []}, Erlang),
    RunTo = lists:max([0 | [L || #{line := L, marker := {"run", ""}} <- Checked]]),
    Classified = [classify(Doc, B) || B <- Checked],
    %% What a run executes: the session blocks up to the last run-marked block.
    RunChunks = lists:append([Chunks || {#{line := L}, {session, Chunks}}
                                            <- lists:zip(Checked, Classified), L =< RunTo]),
    Broken = [F || {error, F} <- Classified],
    Modules = [B || {module, B} <- Classified],
    Forms = [B || {forms, B} <- Classified],
    Sessions = [Chunks || {session, Chunks} <- Classified],
    Compiled = [compile_module(Doc, B, Headers, Work) || B <- Modules]
        ++ [compile_forms(Doc, B, Headers, Work) || B <- Forms]
        ++ [compile_blocks(Doc, Sessions, Headers, Work)],
    Failures = Marked ++ Broken ++ lists:append([E || {error, E} <- Compiled]),
    Loaded = [Loaded || {ok, Loaded} <- Compiled],
    Calls = lists:append([missing_calls(Doc, Fs) || {_, Fs} <- Loaded]),
    Ran = case RunTo > 0 andalso Failures =:= [] andalso Calls =:= [] of
              true -> run_session(Doc, RunChunks, Headers, Work, Opts);
              false -> []
          end,
    Failures ++ Calls ++ Ran.

%% A skip with a reason is not checked; a skip without one, or a marker that is
%% not a marker, is a failure: a block skipped without saying why.
marked(Doc, #{line := L, marker := {"skip", ""}}, F, C) ->
    {[{Doc, L, "skip gives no reason"} | F], C};
marked(_, #{marker := {"skip", _}}, F, C) -> {F, C};
marked(Doc, #{line := L, marker := {"run", Extra}} = B, F, C) when Extra =/= "" ->
    {[{Doc, L, "run takes no argument: " ++ Extra} | F], [B | C]};
marked(Doc, #{line := L, marker := {Word, _}}, F, C) when Word =/= "run" ->
    {[{Doc, L, "unknown marker '" ++ Word ++ "'"} | F], C};
marked(_, B, F, C) -> {F, [B | C]}.

%% --------------------------------------------------------------------------
%% What a block is.

classify(Doc, #{line := L, body := Body} = Block) ->
    case lists:any(fun({_, Line}) -> re:run(Line, ?PROMPT, [{capture, none}, unicode]) =:= match end, Body) of
        true -> shell(Doc, Block);
        false -> source(Doc, L, Body)
    end.

source(Doc, L, Body) ->
    Text = lists:flatten(lists:join("\n", [Line || {_, Line} <- Body])),
    First = case Body of [{N, _} | _] -> N; [] -> L + 1 end,
    case erl_scan:string(Text, First, [text]) of
        {error, {Line, Mod, Desc}, _} -> {error, {Doc, Line, format(Mod, Desc)}};
        %% Only comments: nothing to compile, and nothing wrong with it.
        {ok, [], _} -> {session, []};
        {ok, Tokens, _} ->
            Chunks = chunks(Tokens),
            Kinds = [kind(C) || C <- Chunks],
            case {lists:usort([K || {K, _} <- Kinds]), [E || {error, E} <- Kinds]} of
                {_, [{Line, Mod, Desc} | _]} -> {error, {Doc, Line, format(Mod, Desc)}};
                {[form], []} ->
                    Module = lists:any(fun({form, {attribute, _, module, _}}) -> true;
                                          (_) -> false end, Kinds),
                    {case Module of true -> module; false -> forms end,
                     #{first => First, text => Text}};
                {[exprs], []} -> {session, [{Chunk, Exprs} || {Chunk, {exprs, Exprs}} <- lists:zip(Chunks, Kinds)]};
                _ -> {error, {Doc, First, "mixes forms and expressions; split it in two blocks"}}
            end
    end.

%% A shell session: lines behind a prompt start an expression, lines after an
%% unfinished expression continue it, and every other line is output.
shell(Doc, #{body := Body}) ->
    Inputs = shell_inputs(Body, none, []),
    Scanned = [scan_input(Doc, Input) || Input <- Inputs],
    case [E || {error, E} <- Scanned] of
        [E | _] -> {error, E};
        [] ->
            Chunks = [C || {ok, Tokens} <- Scanned, C <- chunks(Tokens)],
            Kinds = [kind(C) || C <- Chunks],
            case [{Line, format(Mod, Desc)} || {error, {Line, Mod, Desc}} <- Kinds]
                ++ [{form_line(F), "a form in a shell session"} || {form, F} <- Kinds] of
                [{Line, Message} | _] -> {error, {Doc, Line, Message}};
                [] -> {session, [{C, Exprs} || {C, {exprs, Exprs}} <- lists:zip(Chunks, Kinds)]}
            end
    end.

shell_inputs([], none, Acc) -> lists:reverse(Acc);
shell_inputs([], Current, Acc) -> lists:reverse([Current | Acc]);
shell_inputs([{N, Line} | Rest], Current, Acc) ->
    Prompted = re:run(Line, ?PROMPT, [{capture, all_but_first, list}, unicode]),
    case {Prompted, Current} of
        {{match, [Input]}, none} -> shell_inputs(Rest, {N, [Input]}, Acc);
        {{match, [Input]}, {Start, Lines}} ->
            case finished(Lines) of
                true -> shell_inputs(Rest, {N, [Input]}, [Current | Acc]);
                false -> shell_inputs(Rest, {Start, Lines ++ [Input]}, Acc)
            end;
        {nomatch, none} -> shell_inputs(Rest, none, Acc);
        {nomatch, {Start, Lines}} ->
            case finished(Lines) of
                true -> shell_inputs(Rest, none, [Current | Acc]);
                false -> shell_inputs(Rest, {Start, Lines ++ [Line]}, Acc)
            end
    end.

finished(Lines) ->
    case erl_scan:string(lists:flatten(lists:join("\n", Lines))) of
        {ok, Tokens, _} when Tokens =/= [] -> element(1, lists:last(Tokens)) =:= dot;
        _ -> false
    end.

scan_input(Doc, {Start, Lines}) ->
    case erl_scan:string(lists:flatten(lists:join("\n", Lines)), Start, [text]) of
        {ok, Tokens, _} -> {ok, Tokens};
        {error, {Line, Mod, Desc}, _} -> {error, {Doc, Line, format(Mod, Desc)}}
    end.

%% Tokens split at each full stop. A doc often leaves the last one off an
%% example; it is added, so the example is judged on what it says.
chunks(Tokens) -> chunks(Tokens, [], []).

chunks([], [], Acc) -> lists:reverse(Acc);
chunks([], Current, Acc) ->
    Line = erl_scan:line(lists:last(Current)),
    Dot = {dot, erl_anno:set_text(".", erl_anno:new(Line))},
    lists:reverse([lists:reverse([Dot | Current]) | Acc]);
chunks([{dot, _} = Dot | Rest], Current, Acc) -> chunks(Rest, [], [lists:reverse([Dot | Current]) | Acc]);
chunks([T | Rest], Current, Acc) -> chunks(Rest, [T | Current], Acc).

%% A chunk is a form or a sequence of expressions. Macros are read as atoms here,
%% only to tell which: the preprocessor sees the real text when it compiles.
kind(Chunk) ->
    Plain = unmacro(Chunk),
    case erl_parse:parse_form(Plain) of
        {ok, Form} -> {form, Form};
        {error, _} ->
            case erl_parse:parse_exprs(Plain) of
                {ok, Exprs} -> {exprs, Exprs};
                {error, E} -> {error, E}
            end
    end.

unmacro([{'?', A}, {Kind, _, _} | Rest]) when Kind =:= var; Kind =:= atom ->
    [{atom, A, '$macro'} | unmacro(Rest)];
unmacro([T | Rest]) -> [T | unmacro(Rest)];
unmacro([]) -> [].

form_line(Form) -> erl_anno:line(element(2, Form)).

format(Mod, Desc) -> lists:flatten(Mod:format_error(Desc)).

%% --------------------------------------------------------------------------
%% Compiling, with every location in the doc's own lines (the -file attribute
%% renames and renumbers what follows it).

compile_module(Doc, #{first := First, text := Text}, _Headers, Work) ->
    Name = "doc_module_" ++ integer_to_list(erlang:phash2({Doc, First})),
    compile(Doc, Work, Name, [file_attr(Doc, First), Text, "\n"]).

compile_forms(Doc, #{first := First, text := Text}, Headers, Work) ->
    Name = "doc_snippet_" ++ integer_to_list(erlang:phash2({Doc, First})),
    {ok, Tokens, _} = erl_scan:string(Text),
    compile(Doc, Work, Name,
            ["-module(", Name, ").\n-compile([export_all, nowarn_export_all]).\n",
             includes(Tokens, Headers), file_attr(Doc, First), Text, "\n"]).

%% Each session block as a function of its own, whose parameters are the
%% variables it uses and does not bind: a guide fragment that calls
%% macula:publish(Client, ...) is checked for the call, its arity and its
%% syntax without growing the lines that make a Client. The free variables are
%% the compiler's own answer: a first compile names them as unbound, and the
%% second takes them as parameters.
compile_blocks(Doc, Sessions, Headers, Work) ->
    Bodies = [Tokens || Chunks <- Sessions, Tokens <- [kept_tokens(Chunks)], Tokens =/= []],
    case Bodies of
        [] -> {ok, {none, []}};
        _ ->
            Name = "doc_blocks_" ++ integer_to_list(erlang:phash2(Doc)),
            Source = fun(Params) -> blocks_source(Name, Doc, Bodies, Params, Headers) end,
            case compile_raw(Work, Name, Source([[] || _ <- Bodies])) of
                {error, Errors} ->
                    case free_variables(Bodies, Errors) of
                        none -> {error, failures(Doc, Errors)};
                        Params -> compile(Doc, Work, Name, Source(Params))
                    end;
                Compiled -> loaded(Compiled)
            end
    end.

kept_tokens(Chunks) ->
    lists:append([Chunk || {Chunk, Exprs} <- Chunks, not shell_command(Exprs)]).

blocks_source(Name, Doc, Bodies, Params, Headers) ->
    ["-module(", Name, ").\n-compile([export_all, nowarn_export_all]).\n",
     includes(lists:append(Bodies), Headers),
     [begin
          Start = erl_scan:line(hd(Body)) - 1,
          [file_attr(Doc, Start), "block_", integer_to_list(Start), "(",
           lists:join(", ", [atom_to_list(V) || V <- Vars]), ") ->",
           emit(Body, Start, []), "\nok.\n"]
      end || {Body, Vars} <- lists:zip(Bodies, Params)]].

%% The unbound variables of each block, or none when the compile failed for
%% another reason only.
free_variables(Bodies, Errors) ->
    Unbound = [{loc_line(Loc), Var} || {Loc, erl_lint, Desc} <- Errors,
                                       Var <- unbound_var(Desc)],
    case Unbound of
        [] -> none;
        _ ->
            [lists:usort([V || {L, V} <- Unbound, L >= first_line(Body), L =< last_line(Body)])
             || Body <- Bodies]
    end.

unbound_var({unbound_var, Var}) -> [Var];
unbound_var({unbound_var, Var, _}) -> [Var];
unbound_var(_) -> [].

first_line(Tokens) -> erl_scan:line(hd(Tokens)).
last_line(Tokens) -> erl_scan:line(lists:last(Tokens)).

%% Every session block of the doc, in order, as the body of session/0, for a
%% doc that asks to be run. Here a variable must be bound by an earlier block:
%% an example that is executed has nothing to take as a parameter.
compile_session(Doc, Tokens, Headers, Work) ->
    Name = "doc_session_" ++ integer_to_list(erlang:phash2(Doc)),
    Start = erl_scan:line(hd(Tokens)) - 1,
    compile(Doc, Work, Name,
            ["-module(", Name, ").\n-export([session/0]).\n",
             includes(Tokens, Headers), file_attr(Doc, Start),
             "session() ->", emit(Tokens, Start, []), "\nok.\n"]).

shell_command([{call, _, {atom, _, F}, _}]) -> lists:member(F, ?SHELL_COMMANDS);
shell_command(_) -> false.

emit([], _, Acc) -> lists:reverse(Acc);
emit([T | Rest], Line, Acc) ->
    At = erl_scan:line(T),
    Pad = lists:duplicate(max(0, At - Line), $\n),
    Text = case element(1, T) of dot -> ","; _ -> erl_scan:text(T) end,
    emit(Rest, At + count_newlines(Text), [[Pad, " ", Text] | Acc]).

count_newlines(Text) -> length([C || C <- Text, C =:= $\n]).

%% The line after a -file attribute takes the number the attribute names plus
%% one: the attribute line itself is numbered, so `Line` lands on the next line.
file_attr(Doc, Line) -> io_lib:format("-file(~p, ~p).\n", [Doc, Line - 1]).

%% The headers that define the records these tokens use, when the tokens do not
%% define them themselves.
includes(Tokens, Headers) ->
    Used = lists:usort(used_records(Tokens)),
    Defined = defined_records(Tokens),
    Files = lists:usort([maps:get(R, Headers) || R <- Used, not lists:member(R, Defined),
                                                 maps:is_key(R, Headers)]),
    [io_lib:format("-include(~p).\n", [F]) || F <- Files].

used_records([{'#', _}, {atom, _, R} | Rest]) -> [R | used_records(Rest)];
used_records([_ | Rest]) -> used_records(Rest);
used_records([]) -> [].

defined_records([{'-', _}, {atom, _, record}, {'(', _}, {atom, _, R} | Rest]) ->
    [R | defined_records(Rest)];
defined_records([_ | Rest]) -> defined_records(Rest);
defined_records([]) -> [].

compile(Doc, Work, Name, Source) ->
    case compile_raw(Work, Name, Source) of
        {error, Errors} -> {error, failures(Doc, Errors)};
        Compiled -> loaded(Compiled)
    end.

%% {ok, Module, Bin, Forms, File}, or {error, [{Loc, Mod, Desc}]}.
compile_raw(Work, Name, Source) ->
    File = filename:join(Work, Name ++ ".erl"),
    ok = file:write_file(File, unicode:characters_to_binary(Source)),
    case epp:parse_file(File, [{includes, [filename:dirname(File)]}]) of
        {error, Reason} -> {error, [{0, epp, Reason}]};
        {ok, Forms} ->
            case compile:forms(Forms, [binary, return_errors, return_warnings]) of
                {ok, Module, Bin, _Warnings} -> {ok, Module, Bin, Forms, File};
                {error, Errors, _Warnings} -> {error, [E || {_, Es} <- Errors, E <- Es]}
            end
    end.

loaded({ok, Module, Bin, Forms, File}) ->
    load(Module, File, Bin),
    {ok, {Module, Forms}}.

failures(Doc, Errors) ->
    [{Doc, loc_line(Loc), format(Mod, Desc)} || {Loc, Mod, Desc} <- Errors].

%% A doc that shows its own version of a module the repo already has is compiled
%% but not loaded: loading it would replace the real one, and every later call
%% and session would be judged against the doc's copy.
load(Module, File, Bin) ->
    case code:which(Module) of
        non_existing -> {module, Module} = code:load_binary(Module, File, Bin);
        _ -> kept
    end.

loc_line({Line, _}) -> Line;
loc_line(Line) when is_integer(Line) -> Line;
loc_line(_) -> 0.

%% --------------------------------------------------------------------------
%% Calls to functions that do not exist.

missing_calls(Doc, Forms) ->
    lists:usort([{Doc, Line, Why} || {Line, M, F, A} <- remote_calls(Forms),
                                     Why <- [missing(M, F, A)], Why =/= ok]).

remote_calls({call, Anno, {remote, _, {atom, _, M}, {atom, _, F}}, Args}) ->
    [{erl_anno:line(Anno), M, F, length(Args)} | remote_calls(Args)];
remote_calls({'fun', Anno, {function, {atom, _, M}, {atom, _, F}, {integer, _, A}}}) ->
    [{erl_anno:line(Anno), M, F, A}];
remote_calls(Tuple) when is_tuple(Tuple) -> remote_calls(tuple_to_list(Tuple));
remote_calls([H | T]) -> remote_calls(H) ++ remote_calls(T);
remote_calls(_) -> [].

missing(M, F, A) ->
    case code:ensure_loaded(M) of
        {module, M} ->
            case lists:member({F, A}, M:module_info(exports)) of
                true -> ok;
                false -> io_lib:format("~p:~p/~p is not exported", [M, F, A])
            end;
        {error, _} -> io_lib:format("calls ~p:~p/~p, and no module ~p is on the code path", [M, F, A, M])
    end.

%% --------------------------------------------------------------------------
%% Running a session, where the doc says to.

run_session(Doc, Chunks, Headers, Work, #{timeout := Seconds}) ->
    case kept_tokens(Chunks) of
        [] -> [{Doc, 1, "a run marker, and no session to run"}];
        Tokens ->
            case compile_session(Doc, Tokens, Headers, Work) of
                {error, Errors} ->
                    [{D, L, "in the run session: " ++ M} || {D, L, M} <- Errors];
                {ok, {Session, _}} -> execute(Doc, Session, Seconds)
            end
    end.

execute(Doc, Session, Seconds) ->
    {Pid, Ref} = spawn_monitor(fun() ->
                                       exit({result, try Session:session() of
                                                         _ -> ok
                                                     catch C:R:S -> {C, R, S}
                                                     end})
                               end),
    receive
        {'DOWN', Ref, process, Pid, {result, ok}} -> [];
        {'DOWN', Ref, process, Pid, {result, {C, R, S}}} ->
            [{Doc, crash_line(Session, S),
              lists:flatten(io_lib:format("the session raised ~p:~0p", [C, R]))}];
        {'DOWN', Ref, process, Pid, Other} ->
            [{Doc, 1, lists:flatten(io_lib:format("the session died: ~0p", [Other]))}]
    after Seconds * 1000 ->
            exit(Pid, kill),
            [{Doc, 1, lists:flatten(io_lib:format("the session ran past ~p s", [Seconds]))}]
    end.

crash_line(Session, Stack) ->
    case [proplists:get_value(line, Info, 1) || {M, _, _, Info} <- Stack, M =:= Session] of
        [Line | _] -> Line;
        [] -> 1
    end.
