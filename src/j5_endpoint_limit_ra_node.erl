%%%-----------------------------------------------------------------------------
%%% @copyright (C) 2022, 2600Hz
%%% @doc
%%% This Source Code Form is subject to the terms of the Mozilla Public
%%% License, v. 2.0. If a copy of the MPL was not distributed with this
%%% file, You can obtain one at https://mozilla.org/MPL/2.0/.
%%%
%%% @end
%%%-----------------------------------------------------------------------------
-module(j5_endpoint_limit_ra_node). %% Rename module name

-export([start/0, stop/0]).

-export([members/0, members/1
        ,id/0, id/1
        ,app_nodes/0
        ,make_ra_conf/1
        ,maybe_join/0
        ,join/0
        ,restart/0
        ,start_new/0
        ,delete/0
        ,ra_name/0, ra_name/1
        ,available_nodes/0
        ]).

-export([rand_node/0]).

-include("jonny5.hrl").

-define(TICK_INTERVAL, 20 * ?MILLISECONDS_IN_SECOND).

-type ra_name() :: atom().

%%------------------------------------------------------------------------------
%% @doc
%% @end
%%------------------------------------------------------------------------------
-spec cluster_name() -> kz_term:ne_binary().
cluster_name() ->
    kz_term:to_binary(ra_name()).

-spec ra_name() -> ra_name().
ra_name() ->
    kapps_endpoint_limit_ra:ra_name().

-spec ra_name(non_neg_integer()) -> atom().
ra_name(0) ->
    ra_name();
ra_name(I) ->
    kz_term:to_atom(io_lib:format("~s~B", [ra_name(), I]), 'true').

-spec id() -> {atom(), node()}.
id() ->
    {ra_name(), node()}.

-spec id(non_neg_integer()) -> {atom(), node()}.
id(0) ->
    {ra_name(), node()};
id(I) ->
    {ra_name(I), node()}.

-spec members() -> [{ra_name(), node()}].
members() ->
    [{ra_name(), N} || N <- [node() | app_nodes()]].

-spec members(non_neg_integer()) -> [{ra_name(), node()}].
members(I) ->
    [{ra_name(X), N} || N <- [node() | app_nodes()],
                        X <- lists:seq(0, I)
    ].

-spec ra_machine() -> {'module', atom(), map()}.
ra_machine() ->
    {'module', 'kapps_endpoint_limit_ra', ra_machine_config()}.

-spec ra_machine_config() -> map().
ra_machine_config() ->
    #{}.

-spec make_ra_conf({atom(), node()}) -> map().
make_ra_conf(ServerId) ->
    ClusterName = cluster_name(),
    Members = members(),
    UId = ra:new_uid(ra_lib:to_binary(ClusterName)),
    #{cluster_name => ClusterName
     ,id => ServerId
     ,uid => UId
     ,initial_members => Members
     ,log_init_args => #{uid => UId}
     ,tick_timeout => ?TICK_INTERVAL
     ,machine => ra_machine()
     }.

-spec app_nodes() -> [node()].
app_nodes() ->
    Nodes = nodes(),
    {Replies, Bad} = rpc:multicall(Nodes, 'kapps_controller', 'list_apps', []),
    [Node || {Node, Apps} <- lists:zip(Nodes -- Bad, Replies), lists:member(?APP, Apps)].

-spec restart() -> boolean().
restart() ->
    Name = id(),
    case ra:restart_server(Name) of
        'ok' -> 'true';
        {'error', {'already_started', _}} -> 'true';
        {'error', 'not_started'} -> 'false';
        {'error', 'name_not_registered'} -> 'false';
        Err ->
            lager:warning("recover: ra ~w could not be restarted ~w", [Name, Err]),
            'false'
    end.

-spec start() -> any().
start() ->
    ra:start(),
    case restart() of
        'false' -> maybe_join();
        _R -> 'ok'
    end.

-spec maybe_join() -> any().
maybe_join() ->
    case app_nodes() of
        [] -> start_new();
        _ -> join()
    end.

-spec join() -> 'ok' | {'error', any()}.
join() ->
    RaConf = make_ra_conf(id()),
    case ra:start_server(RaConf) of
        'ok' -> join_add_member();
        Else -> Else
    end.

-spec join_add_member() ->
          'ok' |
          ra_server_proc:ra_cmd_ret() |
          {error, already_member} |
          {error, cluster_change_not_permitted}.
join_add_member() ->
    case ra:add_member(members(), id()) of
        {'ok', _, _Leader} -> 'ok';
        Else -> Else
    end.

%% lifted from ra/src/ra.hrl
-type ra_server_id() :: atom() | {Name :: atom(), Node :: node()}.

-spec delete() -> {'ok', ra_server_id()} | {'error', term()}.
delete() ->
    {'ok', Members, _Leader} = ra:members(ra_name()),
    ra:delete_cluster(Members).

-spec start_new() -> 'ok' | {'error', 'cluster_not_formed'}.
start_new() ->
    RaConfs = [make_ra_conf(ServerId) || ServerId <- members()],
    case ra:start_cluster(RaConfs) of
        {'ok', _, _} -> 'ok';
        Else -> Else
    end.

-spec stop() -> 'ok' | {'error', 'nodedown'}.
stop() ->
    ra:stop_server(id()).

-spec available_nodes() -> [node()].
available_nodes() ->
    {'ok', Members, _Leader} = ra:members(ra_name()),
    lists:usort([Node || {_, Node} <- Members, lists:member(Node, nodes())]).

-spec rand_node() -> node().
rand_node() ->
    rand_node(available_nodes()).

-spec rand_node([node()]) -> node().
rand_node([]) ->
    node();
rand_node(Nodes) ->
    Size = length(Nodes),
    Selected = rand:uniform(Size),
    lists:nth(Selected, Nodes).
