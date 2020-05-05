-module(rebar3_cargo_compile_prv).

-export([
    init/1,
    do/1,
    format_error/1
]).

-include("internal.hrl").
-include_lib("kernel/include/file.hrl").

-define(PROVIDER, build).
-define(DEPS, [{default, app_discovery}]).

%% ===================================================================
%% Public API
%% ===================================================================
-spec init(rebar_state:t()) -> {ok, rebar_state:t()}.
init(State) ->
    Provider = providers:create([
            {name, ?PROVIDER},               % The 'user friendly' name of the task
            {namespace, ?NAMESPACE},
            {module, ?MODULE},               % The module implementation of the task
            {bare, true},                    % The task can be run by the user, always true
            {deps, ?DEPS},                   % The list of dependencies
            {example, "rebar3 cargo build"},  % How to use the plugin
            {opts, [
                {flat_output, $f, "flat_output", boolean, "Output libraries directly in priv/ instead of nested by version/mode"}
            ]},                      % list of options understood by the plugin
            {short_desc, "Compile Rust crates"},
            {desc, "Compile Rust crates"}
    ]),
    {ok, rebar_state:add_provider(State, Provider)}.


-spec format_error(any()) ->  iolist().
format_error(Reason) ->
    io_lib:format("~p", [Reason]).

-spec do(rebar_state:t()) -> {ok, rebar_state:t()} | {error, string()}.
do(State) ->
    %% execute for each app
    State1 =
    case rebar_state:current_app(State) of
        undefined ->
            rebar_api:info("No current app, using project apps", []),
            NewApps =
            lists:foldl(fun do_app/2, State, rebar_state:project_apps(State)),
            rebar_state:project_apps(State, NewApps);
        AppInfo ->
            rebar_state:current_app(State, do_app(AppInfo, State))
    end,

    {ok, State1}.

%% process for one application
-spec do_app(rebar_app_info:t(), rebar_state:t()) -> rebar_app_info:t().
do_app(App, State) ->
    % IsRelease = lists:member(prod, rebar_state:current_profiles(State)),
    IsRelease = true,

    {Args, _} = rebar_state:command_parsed_args(State),
    FlatOutput = case proplists:get_value(flat_output, Args) of
        true -> true;
        undefined -> true; %% TODO defaulting this because I can't set in config because rebar3 half-asses plugins
        _ -> false
    end,

    rebar_api:debug("profiles are ~p, release=~p", [rebar_state:current_profiles(State), IsRelease]),

    Cargo = cargo:init(rebar_app_info:dir(App), #{ release => IsRelease }),
    Artifacts = cargo:build(Cargo),

    NifLoadPaths =
    maps:fold(
        fun (_Id, Artifact, Map) ->
            {Name, Path} = do_crate(Artifact, IsRelease, FlatOutput, App),
            Map#{ Name => Path }
        end,
        #{},
        Artifacts
    ),

    ErlOpts = get_defines(NifLoadPaths),

    Opts = rebar_app_info:opts(App),

    ErlOpts1 = ErlOpts ++ rebar_opts:get(Opts, erl_opts, []),
    Opts1 = rebar_opts:set(Opts, erl_opts, ErlOpts1),

    rebar_api:info("Writing crates header...", []),
    write_header(App, NifLoadPaths),

    rebar_app_info:opts(App, Opts1).


do_crate(Artifact, IsRelease, FlatOutput, App) ->
    #{
        name := Name,
        version := Version,
        filenames := Files
    } = Artifact,

    Type = case IsRelease of
        true ->
            "release";
        false ->
            "debug"
    end,

    PrivDir = rebar3_cargo_util:get_priv_dir(App),
    rebar_api:info("Priv dir is ~s", [PrivDir]),


    % TODO: Get "relative" path
    RelativeLoadPath = filename:join(["crates", Name, Version, Type]),
    OutDir = case FlatOutput of
                false -> filename:join([PrivDir, Name, Version, Type]);
                true -> PrivDir
             end,

    filelib:ensure_dir(filename:join([OutDir, "dummy"])),

    rebar_api:info("Copying artifacts for ~s ~s...", [Name, Version]),
    rebar_api:debug("Files are ~p", [Files]),
    [NifLoadPath] = lists:filtermap(
        fun (F) ->
            case cp(F, OutDir) of
                ok ->
                    Filename = filename:basename(F),
                    {true, filename:rootname(filename:join([RelativeLoadPath, Filename]))};
                _ ->
                    false
            end
        end,
        Files
    ),

    rebar_api:info("Load path ~s", [NifLoadPath]),

    {Name, NifLoadPath}.


-spec write_header(rebar_app_info:t(), #{ binary() => filename:type() }) -> ok.
write_header(App, NifLoadPaths) ->
    Define = "CRATES_HRL",
    FuncDefine = "FUNC_CRATES_HRL",

    Hrl = [
        "-ifndef(", Define, ").\n",
        "-define(", Define, ", 1).\n",
        [
            io_lib:format("-define(crate_~s, ~p).~n", [Name, undefined])
            || Name <- maps:keys(NifLoadPaths)
        ],
        "-endif.\n"
        "-ifndef(", FuncDefine, ").\n",
        "-define(", FuncDefine, ", 1).\n",
        "-define(load_nif_from_crate(__APP,__CRATE,__INIT),"
            "(fun()->"
            "__PATH=filename:join(code:priv_dir(__APP),__CRATE),"
            "erlang:load_nif(__PATH,__INIT)"
            "end)()"
        ").\n",
        "-endif.\n"
    ],

    OutDir = rebar_app_info:dir(App),
    OutPath = filename:join([OutDir, "src", "crates.hrl"]),
    filelib:ensure_dir(OutPath),

    file:write_file(OutPath, Hrl).


get_defines(NifLoadPaths) ->
    Opts = [
        get_define(Name, Path) || {Name, Path} <- maps:to_list(NifLoadPaths)
    ],

    [{d, 'CRATES_HRL', 1} | Opts].


get_define(Name, Path) ->
    D = binary_to_atom(
        list_to_binary(io_lib:format("crate_~s", [Name])),
        utf8
    ),

    % TODO: This must be relative to code:priv_dir
    {d, D, binary_to_list(list_to_binary([Path]))}.


-spec cp(filename:type(), filename:type()) -> ok | {error, ignored}.
cp(Src, Dst) ->
    OsType = os:type(),
    Ext = filename:extension(Src),
    Fname = filename:basename(Src),

    case cargo_util:check_extension(Ext, OsType) of
        true ->
            Fname1 = case Fname of
                        <<"lib", X/binary>> -> X;
                        _ -> Fname
                     end,
            rebar_api:info("  Copying ~s as ~s...", [Fname, Fname1]),

            OutPath = filename:join([
                Dst,
                Fname1
            ]),

            {ok, _} = file:copy(Src, OutPath),
            rebar_api:info("  Output path ~s...", [OutPath]),

            ok;
        _ ->
            rebar_api:debug("  Ignoring ~s", [Fname]),
            {error, ignored}
    end.
