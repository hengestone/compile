%% Copyright (c) 2009, Dave Smith <dizzyd@dizzyd.com> &
%%                     Tim Dysinger <tim@dysinger.net>
%% Copyright (c) 2014, 2015 Duncan McGreggor <oubiwann@gmail.com>
%%
-module('lfe-compile').
-behaviour(provider).

-export([init/1,
         do/1,
         format_error/1]).

-export([compile/2,
         lfe_compile/3]).

-define(PROVIDER, compile).
-define(DESC, "The LFE rebar3 compiler plugin").
-define(DEPS, [{default, compile},
               {default, app_discovery}]).
-define(RE_PREFIX, "^[^._]").

%% ===================================================================
%% Public API
%% ===================================================================
-spec init(rebar_state:t()) -> {ok, rebar_state:t()}.
init(State) ->
    rebar_log:log(debug, "Initializing {lfe, compile} ...", []), %% XXX DEBUG
    Provider = providers:create([
            {name, compile},
            {module, ?MODULE},
            {namespace, lfe},
            {bare, true},
            {deps, ?DEPS},
            {example, "rebar3 lfe compile"},
            {short_desc, ?DESC},
            {desc, info(?DESC)},
            {opts, []}
    ]),
    State1 = rebar_state:add_provider(State, Provider),
    rebar_log:log(debug, "Initialized {lfe, compile} ...", []), %% XXX DEBUG
    {ok, State1}.


-spec do(rebar_state:t()) -> {ok, rebar_state:t()} | {error, string()}.
do(State) ->
    rebar_api:debug("Starting do/1 for {lfe, compile} ...", []),
    case rebar_state:get(State, escript_main_app, undefined) of
        undefined ->
            Dir = rebar_state:dir(State),
            case rebar_app_discover:find_app(Dir, all) of
                {true, AppInfo} ->
                    AllApps = rebar_state:project_apps(State) ++ rebar_state:all_deps(State),
                    case rebar_app_utils:find(rebar_app_info:name(AppInfo), AllApps) of
                        {ok, AppInfo1} ->
                            %% Use the existing app info instead of newly created one
                            compile(State, AppInfo1);
                        _ ->
                            compile(State, AppInfo)
                    end,
                    {ok, State};
                _ ->
                    {error, {?MODULE, no_main_app}}
            end;
        Name ->
            AllApps = rebar_state:project_apps(State) ++ rebar_state:all_deps(State),
            {ok, App} = rebar_app_utils:find(Name, AllApps),
            compile(State, App),
            {ok, State}
    end.

-spec format_error(any()) -> iolist().
format_error({missing_artifact, File}) ->
    io_lib:format("Missing artifact ~s", [File]);
format_error(Reason) ->
    io_lib:format("~p", [Reason]).

compile(State, AppInfo) ->
    AppDir = rebar_app_info:dir(AppInfo),
    OutDir = filename:join(AppDir, "ebin"),
    rebar_api:debug("Calculated outdir: ~p", [OutDir]), %% XXX DEBUG
    lfe_compile(State, AppDir, OutDir).

-spec lfe_compile(rebar_state:t(), file:name(), file:name()) -> 'ok'.
lfe_compile(State, Dir, OutDir) ->
    dotlfe_compile(State, Dir, OutDir).

%% ===================================================================
%% Internal functions
%% ===================================================================
info(Description) ->
    io_lib:format(
        "~n~s~n"
        "~n"
        "No additional configuration options are required to compile~n"
        "LFE (*.lfe) files. The rebar 'erl_opts' setting is reused by~n"
        "LFE. For more information, see the rebar documentation for~n"
        "'erl_opts'.~n",
        [Description]).

-spec dotlfe_compile(rebar_state:t(), file:filename(), file:filename()) -> ok.
dotlfe_compile(State, Dir, OutDir) ->
    rebar_api:debug("Starting dotlfe_compile/3 ...", []), %% XXX DEBUG
    ErlOpts = rebar_utils:erl_opts(State),
    LfeFirstFiles = check_files(rebar_state:get(State, lfe_first_files, [])),
    dotlfe_compile(State, Dir, OutDir, [], ErlOpts, LfeFirstFiles).

dotlfe_compile(State, Dir, OutDir, MoreSources, ErlOpts, LfeFirstFiles) ->
    rebar_api:debug("Starting dotlfe_compile/6 ...", []), %% XXX DEBUG
    rebar_api:debug("erl_opts ~p", [ErlOpts]),
    %% Support the src_dirs option allowing multiple directories to
    %% contain erlang source. This might be used, for example, should
    %% eunit tests be separated from the core application source.
    SrcDirs = [filename:join(Dir, X) || X <- rebar_dir:all_src_dirs(State, ["src"], [])],
    AllLfeFiles = gather_src(SrcDirs, []) ++ MoreSources,

    %% Make sure that ebin/ exists and is on the path
    ok = filelib:ensure_dir(filename:join(OutDir, "dummy.beam")),
    true = code:add_patha(filename:absname(OutDir)),

    OutDir1 = proplists:get_value(outdir, ErlOpts, OutDir),
    rebar_api:debug("Files to compile first: ~p", [LfeFirstFiles]),
    rebar_base_compiler:run(
      State, LfeFirstFiles, AllLfeFiles,
      fun(S, C) ->
          internal_lfe_compile(C, Dir, S, OutDir1, ErlOpts)
      end),
    ok.

%%
%% Ensure all files in a list are present and abort if one is missing
%%
-spec check_files([file:filename()]) -> [file:filename()].
check_files(FileList) ->
    [check_file(F) || F <- FileList].

check_file(File) ->
    case filelib:is_regular(File) of
        false -> rebar_utils:abort("File ~p is missing, aborting\n", [File]);
        true -> File
    end.

gather_src([], Srcs) ->
    Srcs;
gather_src([Dir|Rest], Srcs) ->
    gather_src(
      Rest, Srcs ++ rebar_utils:find_files(Dir, ?RE_PREFIX".*\\.lfe\$")).

target_base(OutDir, Source) ->
    filename:join(OutDir, filename:basename(Source, ".lfe")).

-spec internal_lfe_compile(rebar_config:config(), file:filename(), file:filename(),
    file:filename(), list()) -> ok | {ok, any()} | {error, any(), any()}.
internal_lfe_compile(Config, Dir, Module, OutDir, ErlOpts) ->
    Target = target_base(OutDir, Module) ++ ".beam",
    rebar_api:debug("Compiling ~p~n\tto ~p ...", [Module, Target]),
    ok = filelib:ensure_dir(Target),
    Opts = [{outdir, filename:dirname(Target)}] ++ ErlOpts ++
        [{i, filename:join(Dir, "include")}, return],
    case lfe_comp:file(Module, Opts) of
        {ok, _Mod} ->
            ok;
        {ok, _Mod, Ws} ->
            rebar_base_compiler:ok_tuple(Config, Module, Ws);
        {error, Es, Ws} ->
            rebar_base_compiler:error_tuple(Config, Module, Es, Ws, Opts)
    end.
