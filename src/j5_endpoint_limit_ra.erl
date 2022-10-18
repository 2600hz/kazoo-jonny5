%%%-----------------------------------------------------------------------------
%%% @copyright (C) 2022, 2600Hz
%%% @doc RA (Raft) integration
%%% This Source Code Form is subject to the terms of the Mozilla Public
%%% License, v. 2.0. If a copy of the MPL was not distributed with this
%%% file, You can obtain one at https://mozilla.org/MPL/2.0/.
%%%
%%% @end
%%%-----------------------------------------------------------------------------
-module(j5_endpoint_limit_ra).
-behaviour(ra_machine).

-compile({no_auto_import, [apply/3]}).

%% API {
%% Commands
-export([reserve/2
        ,release/1
        ]).
%% Queries
-export([reservations/0
        ,reservations/1
        ,reservations/2
        ]).
%% }

%% ra_machine callbacks
-export([init/1
        ,apply/3
        ,state_enter/2
        ,tick/2
        ,overview/1
        ]).

-type account_id() :: kz_term:ne_binary().
-type endpoint_id() :: kz_term:ne_binary().
-type uuid() :: kz_term:ne_binary().
-type uuids() :: [uuid()].
-type reserved() :: non_neg_integer().
-type available() :: non_neg_integer().
-type state() :: #{accounts => #{account_id() => #{endpoint_id() => #{'uuids' => uuids()
                                                                     ,'limit' => non_neg_integer()
                                                                     }}}
                  ,uuids => #{uuid() => {account_id(), endpoint_id()}}
                  ,name => atom()
                  ,trans_count => non_neg_integer() %% Total reservations counter for overview/1 function.
                  }.
-type command() :: {'reserve', {account_id(), endpoint_id()}} |
                   {'release', uuid()} |
                   {'reservations', {account_id() | 'undefined', endpoint_id() | 'undefined'}}.
-type reservations() :: uuids() |
                        #{endpoint_id() => uuids()} |
                        #{account_id() => #{endpoint_id() => uuids()}}.
-type reserve_ok_resp() :: {'ok', uuid(), reserved(), available()}.
-type reserve_error_resp() :: {'error', 486 | 'unknown_command' | 'timeout' | 'invalid_endpoint_id'} |
                              kz_datamgr:data_error().
-type release_resp() :: {'ok', reserved(), available()} | {'error', 'not_found'}.
-type reservations_summary() :: {'ok', reservations()} | {'error', term()}.

-export_type([account_id/0
             ,endpoint_id/0
             ,uuid/0
             ,reserve_ok_resp/0
             ,reserve_error_resp/0
             ,release_resp/0
             ,reservations_summary/0
             ]).

%%%=============================================================================
%%% Commands
%%%=============================================================================

%%------------------------------------------------------------------------------
%% @doc Makes a new reservation if endpoint has not reached limit, yet.
%% @end
%%------------------------------------------------------------------------------
-spec reserve(account_id(), endpoint_id()) -> reserve_ok_resp() | reserve_error_resp().
reserve(AccountId, EndpointId) ->
    process_command({'reserve', {AccountId, EndpointId}}).

%%------------------------------------------------------------------------------
%% @doc Frees EndpointId's reservation.
%% @end
%%------------------------------------------------------------------------------
-spec release(uuid()) -> release_resp().
release(UUID) ->
    process_command({'release', UUID}).

%%%=============================================================================
%%% Queries
%%%=============================================================================

%%------------------------------------------------------------------------------
%% @doc Reservations listing.
%% @end
%%------------------------------------------------------------------------------
-spec reservations() -> reservations_summary().
reservations() ->
    reservations('undefined').

%%------------------------------------------------------------------------------
%% @doc Reservations per Account listing.
%% @end
%%------------------------------------------------------------------------------
-spec reservations(account_id() | 'undefined') -> reservations_summary().
reservations(AccountId) ->
    reservations(AccountId, 'undefined').

%%------------------------------------------------------------------------------
%% @doc Reservations per EndpointId listing.
%% @end
%%------------------------------------------------------------------------------
-spec reservations(account_id() | 'undefined', endpoint_id() | 'undefined') -> reservations_summary().
reservations(AccountId, EndpointId) ->
    kz_log:put_callid(kz_log:get_callid()),
    query_state(reservations_query_fun(AccountId, EndpointId)).

%%%=============================================================================
%%% ra_machine callbacks
%%%=============================================================================

%%------------------------------------------------------------------------------
%% @doc
%% @end
%%------------------------------------------------------------------------------
-spec init(map()) -> state().
init(#{'name' := Name}=_Config) ->
    #{'name' => Name
     ,'trans_count' => 0
     ,'accounts' => #{}
     ,'uuids' => #{}
     }.

%%------------------------------------------------------------------------------
%% @doc
%% @end
%%------------------------------------------------------------------------------
-spec apply(ra_machine:command_meta_data(), command(), state()) ->
          {state(), reserve_ok_resp() | release_resp() | reservations_summary(), ra_machine:effects()} |
          {state(), reserve_error_resp()}.
apply(_CmdMD, {'reserve', {AccountId, EndpointId}}, State) ->
    kz_log:put_callid(kz_log:get_callid()),
    make_reservation(State, AccountId, EndpointId);
apply(_CmdMD, {'release', UUID}, State) ->
    kz_log:put_callid(kz_log:get_callid()),
    release_reservation(State, UUID);
apply(_CmdMD, _Cmd, State) ->
    lager:debug("received unknown command: ~p", [_Cmd]),
    {State, {'error', 'unknown_command'}}.

%%------------------------------------------------------------------------------
%% @doc Triggered every time there is a ra_state change for this node.
%% @end
%%------------------------------------------------------------------------------
-spec state_enter(ra_server:ra_state(), state()) -> ra_machine:effects().
state_enter(_RaState, _State) ->
    lager:debug("entering into ~s ra_state", [_RaState]),
    [].

%%------------------------------------------------------------------------------
%% @doc Triggered every `_Ts'ms.
%% @end
%%------------------------------------------------------------------------------
-spec tick(non_neg_integer(), state()) -> ra_machine:effects().
tick(_Ts, _State) ->
    [].

%%------------------------------------------------------------------------------
%% @doc Triggered when `sys:get_state(j5_endpoint_limit_ra_node:ra_name())' is executed.
%% @end
%%------------------------------------------------------------------------------
-spec overview(state()) -> map().
overview(#{'name' := Name, 'trans_count' := Total}) ->
    #{'type' => Name
     ,'reservations' => Total
     }.

%%%=============================================================================
%%% Helpers
%%%=============================================================================

%%------------------------------------------------------------------------------
%% @doc
%% @end
%%------------------------------------------------------------------------------
-spec process_command(command()) -> reserve_ok_resp() | reserve_error_resp() | release_resp().
process_command(Cmd) ->
    case ra:process_command(j5_endpoint_limit_ra_node:ra_name(), Cmd) of
        {'timeout', _} ->
            {'error', 'timeout'};
        {'error', _}=Error ->
            Error;
        {'ok', Reply, _ServerId} ->
            Reply
    end.

-spec make_reservation(state(), account_id(), endpoint_id()) ->
          {state(), reserve_ok_resp(), ra_machine:effects()} |
          {state(), reserve_error_resp()}.
make_reservation(State, AccountId, EndpointId) ->
    lager:debug("trying to make a reservation for ~s/~s", [AccountId, EndpointId]),
    Endpoint = kz_endpoint:get(EndpointId, AccountId),
    make_reservation(State, AccountId, EndpointId, Endpoint).

-spec make_reservation(state(), account_id(), endpoint_id(), kz_endpoint:std_return()) ->
          {state(), reserve_ok_resp(), ra_machine:effects()} |
          {state(), reserve_error_resp()}.
make_reservation(State, _AccountId, _EndpointId, {'error', _}=Err) ->
    lager:debug("failed to reserve because endpoint load failed with: ~p", [Err]),
    {State, Err};
make_reservation(State, AccountId, EndpointId, {'ok', Endpoint}) ->
    Limit = kzd_call_limits:max_concurrent(kzd_endpoint:call_limits(Endpoint)),
    Reserved = kz_maps:get(['accounts', AccountId, EndpointId, 'uuids'], State, []),
    ReservedCount = length(Reserved),
    lager:debug("Limit: ~B, Reserved: ~B", [Limit, ReservedCount]),
    case Limit > ReservedCount of
        'true' ->
            UUID = kz_binary:rand_uuid(),
            lager:debug("adding ~s/~s/~s reservation", [AccountId, EndpointId, UUID]),
            NewReservedCount = ReservedCount + 1,
            {State#{'accounts' => kz_maps:put([AccountId, EndpointId]
                                             ,kz_maps:get('accounts', State)
                                             ,#{'uuids' => [UUID | Reserved]
                                                %% Used later at release step for the response.
                                                %% To avoid fetching endpoint information again.
                                               ,'limit' => Limit
                                               }
                                             )
                    %% Used to find the account_id and endpoint_id when releasing a reservation.
                   ,'uuids' => kz_maps:put(UUID
                                          ,kz_maps:get('uuids', State)
                                          ,{AccountId, EndpointId}
                                          )
                   ,'trans_count' => kz_maps:get('trans_count', State) + 1
                   }
            ,{'ok', UUID, NewReservedCount, Limit - NewReservedCount}
            ,[]
            };
        'false' ->
            lager:debug("~s/~s already has ~B out of ~B reservations, denying reservation",
                        [AccountId, EndpointId, ReservedCount, Limit]),
            {State, {'error', 486}}
    end.

-spec release_reservation(state(), uuid()) -> {state(), release_resp(), ra_machine:effects()}.
release_reservation(State, UUID) ->
    lager:debug("trying to release ~s", [UUID]),
    release_reservation(State, UUID, kz_maps:get(['uuids', UUID], State)).

-spec release_reservation(state(), uuid(), {account_id(), endpoint_id()} | 'undefined') ->
          {state(), release_resp(), ra_machine:effects()}.
release_reservation(State, UUID, 'undefined') ->
    lager:debug("reservation ~s not found", [UUID]),
    {State, {'error', 'not_found'}};
release_reservation(#{'trans_count' := TransCount, 'accounts' := AccountsMap}=State
                   ,UUID
                   ,{AccountId, EndpointId}
                   ) ->
    Reserved = kz_maps:get(['accounts', AccountId, EndpointId, 'uuids'], State),
    Limit = kz_maps:get(['accounts', AccountId, EndpointId, 'limit'], State),
    AccountMap = kz_maps:get(AccountId, AccountsMap),
    NewUUIDs = kz_maps:remove(UUID, kz_maps:get('uuids', State)),
    NewTransCount = TransCount - 1,
    case lists:delete(UUID, Reserved) of
        [] -> %% Not reservations associated to this account_id->endpoint_id key anymore.
            lager:debug("releasing ~s/~s/~s reservation", [AccountId, EndpointId, UUID]),
            %% Remove accounts->account_id->endpoint_id and uuids->uuid keys from state.
            {State#{'accounts' => kz_maps:put(AccountId
                                             ,AccountsMap
                                             ,kz_maps:remove(EndpointId, AccountMap)
                                             )
                   ,'uuids' => NewUUIDs
                   ,'trans_count' => NewTransCount
                   }
            ,{'ok', 0, Limit} %% 0 reserved, {Limit} available.
            ,[]
            };
        NewReserved ->
            lager:debug("releasing ~s/~s/~s reservation", [AccountId, EndpointId, UUID]),
            NewReservedCount = length(NewReserved),
            {State#{'accounts' => kz_maps:put([AccountId, EndpointId, 'uuids']
                                             ,AccountsMap
                                             ,NewReserved
                                             )
                   ,'uuids' => NewUUIDs
                   ,'trans_count' => NewTransCount
                   }
            ,{'ok', NewReservedCount, Limit - NewReservedCount}
            ,[]
            }
    end.

-spec reservations_query_fun(account_id() | 'undefined', endpoint_id() | 'undefined') ->
          fun((state()) -> reservations()).
reservations_query_fun('undefined', _EndpointId) -> %% List all the existing reservations.
    fun(State) ->
            kz_maps:remove(['name', 'trans_count', 'uuids'], State) end;
reservations_query_fun(AccountId, 'undefined') -> %% List account's reservations.
    fun(State) -> kz_maps:get(['accounts', AccountId], State, #{}) end;
reservations_query_fun(AccountId, EndpointId) -> %% List endpoint's reservations.
    fun(State) -> kz_maps:get(['accounts', AccountId, EndpointId], State, []) end.

-spec query_state(fun((state()) -> reservations())) -> reservations_summary().
query_state(Fun) ->
    case ra:local_query(j5_endpoint_limit_ra_node:ra_name(), Fun) of
        {'timeout', _}=_Error ->
            lager:debug("timed out querying state with error: ~p", [_Error]),
            {'error', 'timeout'};
        {'error', _}=Error ->
            lager:debug("failed to query state with error: ~p", [Error]),
            Error;
        {'ok', {_RaIdxTerm, Reservations}, _ServerId} ->
            {'ok', Reservations}
    end.
