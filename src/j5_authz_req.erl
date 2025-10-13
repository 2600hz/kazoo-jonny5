%%%-----------------------------------------------------------------------------
%%% @copyright (C) 2012-2025, 2600Hz
%%% @doc Handlers for various AMQP payloads
%%%
%%% This Source Code Form is subject to the terms of the Mozilla Public
%%% License, v. 2.0. If a copy of the MPL was not distributed with this
%%% file, You can obtain one at https://mozilla.org/MPL/2.0/.
%%%
%%% @end
%%%-----------------------------------------------------------------------------
-module(j5_authz_req).

-export([handle_req/2]).

-include("jonny5.hrl").

-define(BYPASS_AUTHZ_CLASSIFIERS
       ,kapps_config:get(?APP_NAME
                        ,<<"bypass_authz_classifiers">>
                        ,[kz_json:from_list([{<<"classifier">>,<<"emergency">>}])
                         ,kz_json:from_list([{<<"classifier">>,<<"tollfree_us">>}
                                            ,{<<"direction">>,<<"outbound">>}
                                            ]
                                           )
                         ]
                        )
       ).

-spec handle_req(kapi_authz:req(), kz_term:proplist()) -> 'ok'.
handle_req(JObj, _) ->
    kz_log:put_callid(JObj),
    'true' = kapi_authz:authz_req_v(JObj),
    Request = j5_request:from_jobj(JObj),
    Direction = j5_request:call_direction(Request),
    authorize_direction(Request, Direction).

-spec authorize_direction(j5_request:request(), kz_term:ne_binary()) -> 'ok'.
authorize_direction(Request, <<"inbound">>) ->
    Number = j5_request:number(Request),
    maybe_local_resource(Request, Number);
authorize_direction(Request, <<"outbound">>) ->
    NumberProps = number_props_from_request(Request),
    maybe_account_limited(Request, NumberProps).

-spec maybe_local_resource(j5_request:request(), kz_term:api_ne_binary()) -> 'ok'.
maybe_local_resource(Request, Number) ->
    case knm_numbers:lookup_account(Number) of
        {'ok', _AccountId, Props} ->
            lager:debug("number ~s belongs to ~s", [Number, _AccountId]),
            maybe_account_limited(Request, Props);
        {'error', _R} ->
            lager:warning("error confirming number's account id (~s) for ~s: ~p"
                         ,[j5_request:account_id(Request), Number, _R]
                         ),
            NumberProps = number_props_from_request(Request),
            maybe_account_limited(Request, NumberProps)
    end.

-spec number_props_from_request(j5_request:request()) -> knm_options:extra_options().
number_props_from_request(Request) ->
    props:filter_undefined(
      [{'module_name', kz_json:get_ne_binary_value(<<"Authz-Number-Module">>, j5_request:ccvs(Request))}]
     ).

-spec maybe_account_limited(j5_request:request(), knm_options:extra_options()) -> 'ok'.
maybe_account_limited(Request, NumberProps) ->
    AccountId = j5_request:account_id(Request),
    JObj = j5_request:to_jobj(Request),
    case knm_numbers:maybe_account_limited(NumberProps, JObj) of
        'false' ->
            lager:info("account ~s limits are disabled by resource module ~s"
                      ,[AccountId, knm_options:module_name(NumberProps)]
                      ),
            AccountDisabled = j5_request:authorize_account(<<"limits_disabled">>, Request),
            maybe_reseller_limited(AccountDisabled, NumberProps);
        _ ->
            AccountId = j5_request:account_id(Request),
            Limits = j5_limits:get(AccountId),
            R = maybe_authorize(Request, Limits),
            case j5_request:is_authorized(R, Limits) of
                'true' -> maybe_reseller_limited(R, NumberProps);
                'false' ->
                    lager:info("account ~s is not authorized to create this channel"
                              ,[AccountId]
                              ),
                    send_response(R)
            end
    end.

-spec maybe_reseller_limited(j5_request:request(), knm_options:extra_options()) -> 'ok'.
maybe_reseller_limited(Request, NumberProps) ->
    ResellerId = j5_request:reseller_id(Request),
    case j5_request:account_id(Request) =:= ResellerId of
        'true' ->
            lager:info("channel belongs to reseller, ignoring reseller billing"),
            send_response(
              j5_request:authorize_reseller(<<"limits_disabled">>, Request)
             );
        'false' ->
            JObj = j5_request:to_jobj(Request),
            case knm_numbers:maybe_reseller_limited(NumberProps, JObj) of
                'false' ->
                    lager:info("reseller ~s limits are disabled by resource module ~s", [ResellerId, NumberProps]),
                    send_response(
                      j5_request:authorize_reseller(<<"limits_disabled">>, Request)
                     );
                _ ->
                    check_reseller_limits(Request, ResellerId)
            end
    end.

-spec check_reseller_limits(j5_request:request(), kz_term:ne_binary()) -> 'ok'.
check_reseller_limits(Request, ResellerId) ->
    Limits = j5_limits:get(ResellerId),
    R = maybe_authorize(Request, Limits),

    maybe_log_if_unauthz(j5_request:is_authorized(R, Limits), ResellerId),
    send_response(R).

maybe_log_if_unauthz('true', _ResellerId) -> 'ok';
maybe_log_if_unauthz('false', ResellerId) ->
    lager:info("reseller ~s is not authorized to create this channel"
              ,[ResellerId]
              ).

-spec maybe_authorize(j5_request:request(), j5_limits:limits()) ->
          j5_request:request().
maybe_authorize(Request, Limits) ->
    case j5_limits:enabled(Limits) of
        'true' -> maybe_authorize_exception(Request, Limits);
        'false' ->
            lager:debug("limits are disabled for account ~s"
                       ,[j5_limits:account_id(Limits)]
                       ),
            j5_request:authorize(<<"limits_disabled">>, Request, Limits)
    end.

-spec maybe_authorize_exception(j5_request:request(), j5_limits:limits()) -> j5_request:request().
maybe_authorize_exception(Request, Limits) ->
    Routines = [fun maybe_authorize_mobile/2
               ,fun maybe_authorize_resource_type/2
               ,fun maybe_authorize_classification/2
               ],
    Result = lists:foldl(fun(F, R) ->
                                 case j5_request:is_authorized(R, Limits) of
                                     'false' -> F(R, Limits);
                                     'true' -> R
                                 end
                         end
                        ,Request
                        ,Routines
                        ),
    maybe_hard_limit(Result, Limits).

-spec maybe_authorize_mobile(j5_request:request(), j5_limits:limits()) -> j5_request:request().
maybe_authorize_mobile(Request, Limits) ->
    AuthType = kz_json:get_value(<<"Authorizing-Type">>, j5_request:ccvs(Request)),

    case AuthType =:= <<"mobile">> of
        'true' ->
            lager:debug("allowing mobile call"),
            j5_per_minute:authorize(Request, Limits);
        'false' -> Request
    end.

-spec maybe_authorize_resource_type(j5_request:request(), j5_limits:limits()) -> j5_request:request().
maybe_authorize_resource_type(Request, Limits) ->
    ResourceType = kz_json:get_value(<<"Resource-Type">>, j5_request:ccvs(Request)),

    case lists:member(ResourceType, j5_limits:authz_resource_types(Limits)) of
        'true' ->
            lager:debug("allowing ~s call", [ResourceType]),
            j5_request:authorize(<<"limits_disabled">>, Request, Limits);
        'false' -> Request
    end.

-spec maybe_authorize_classification(j5_request:request(), j5_limits:limits()) -> j5_request:request().
maybe_authorize_classification(Request, Limits) ->
    CallClassification = j5_request:classification(Request),
    CallDirection = j5_request:call_direction(Request),
    maybe_authz_classifiers(Request, Limits, CallClassification, CallDirection, ?BYPASS_AUTHZ_CLASSIFIERS).

-spec maybe_authz_classifiers(j5_request:request(), j5_limits:limits(), kz_term:ne_binary(), kz_term:ne_binary(), kz_json:objects()) -> j5_request:request().
maybe_authz_classifiers(Request, _Limits, _CallClassification, _CallDirection, [])->
    Request;
maybe_authz_classifiers(Request, Limits, CallClassification, CallDirection, [Bypass | Bypasses]) ->
    case {kz_json:get_ne_binary_value(<<"classifier">>, Bypass)
         ,kz_json:get_ne_binary_value(<<"direction">>, Bypass)
         }
    of
        {CallClassification, 'undefined'} ->
            lager:debug("bypass classifier ~s, allowing call", [CallClassification]),
            j5_request:authorize(<<"limits_disabled">>, Request, Limits);
        {CallClassification, CallDirection} ->
            lager:debug("bypass classifier ~s direction ~s, allowing call", [CallClassification, CallDirection]),
            j5_request:authorize(<<"limits_disabled">>, Request, Limits);
        _Else ->
            maybe_authz_classifiers(Request, Limits, CallClassification, CallDirection, Bypasses)
    end.

-spec maybe_hard_limit(j5_request:request(), j5_limits:limits()) -> j5_request:request().
maybe_hard_limit(Request, Limits) ->
    R = j5_hard_limit:authorize(Request, Limits),
    case j5_request:billing(R, Limits) of
        <<"hard_limit">> -> maybe_soft_limit(R, Limits);
        _Else -> authorize(R, Limits)
    end.

-spec authorize(j5_request:request(), j5_limits:limits()) -> j5_request:request().
authorize(Request, Limits) ->
    Routines = [fun j5_allotments:authorize/2
               ,fun j5_flat_rate:authorize/2
               ,fun j5_per_minute:authorize/2
               ],
    Result = lists:foldl(fun(F, R) ->
                                 case j5_request:is_authorized(R, Limits) of
                                     'false' -> F(R, Limits);
                                     'true' -> R
                                 end
                         end
                        ,Request
                        ,Routines
                        ),
    maybe_soft_limit(Result, Limits).

-spec maybe_soft_limit(j5_request:request(), j5_limits:limits()) -> j5_request:request().
maybe_soft_limit(Request, Limits) ->
    case j5_request:is_authorized(Request) of
        'true' -> Request;
        'false' ->
            case j5_request:call_direction(Request) of
                <<"outbound">> -> maybe_outbound_soft_limit(Request, Limits);
                <<"inbound">> -> maybe_inbound_soft_limit(Request, Limits)
            end
    end.

-spec maybe_outbound_soft_limit(j5_request:request(), j5_limits:limits()) -> j5_request:request().
maybe_outbound_soft_limit(Request, Limits) ->
    case j5_limits:soft_limit_outbound(Limits) of
        'false' -> Request;
        'true' ->
            lager:debug("outbound channel authorization is not enforced (soft limit)"),
            j5_request:set_soft_limit(Request)
    end.

-spec maybe_inbound_soft_limit(j5_request:request(), j5_limits:limits()) -> j5_request:request().
maybe_inbound_soft_limit(Request, Limits) ->
    case j5_limits:soft_limit_inbound(Limits) of
        'false' -> Request;
        'true' ->
            lager:debug("inbound channel authorization is not enforced (soft limit)"),
            j5_request:set_soft_limit(Request)
    end.

-define(AUTZH_TYPES_FOR_OUTBOUND, [<<"account">>
                                  ,<<"user">>
                                  ,<<"device">>
                                  ,<<"mobile">>
                                  ]).

-spec maybe_get_outbound_flags(kz_term:api_binary(), kz_term:api_binary(), kz_term:ne_binary()) -> kz_term:api_binary().
maybe_get_outbound_flags('undefined', _AuthId, _AccountDb) -> 'undefined';
maybe_get_outbound_flags(_AuthType, 'undefined', _AccountDb) -> 'undefined';
maybe_get_outbound_flags(AuthType, AuthId, AccountDb) ->
    case lists:member(AuthType, ?AUTZH_TYPES_FOR_OUTBOUND)
        andalso kz_endpoint:get(AuthId, AccountDb)
    of
        {'ok', Endpoint} -> get_outbound_flags(Endpoint);
        _ -> 'undefined'
    end.

-spec get_outbound_flags(kz_json:object()) -> kz_term:api_binary().
get_outbound_flags(Endpoint) ->
%%% TODO: without a kapps_call we can not support dynamic
%%%     flags yet
    case kzd_devices:outbound_static_flags(Endpoint) of
        [] -> 'undefined';
        Flags -> Flags
    end.

-spec send_response(j5_request:request()) -> 'ok'.
send_response(Request) ->
    ServerId  = j5_request:server_id(Request),
    AccountDb = kzs_util:format_account_db(j5_request:account_id(Request)),
    AuthType  = kz_json:get_ne_binary_value(<<"Authorizing-Type">>, j5_request:ccvs(Request)),
    AuthId    = kz_json:get_ne_binary_value(<<"Authorizing-ID">>, j5_request:ccvs(Request)),

    OutboundFlags = maybe_get_outbound_flags(AuthType, AuthId, AccountDb),

    CCVs = kz_json:from_list(
             [{<<"Account-Trunk-Usage">>, trunk_usage(j5_request:account_id(Request))}
             ,{<<"Reseller-Trunk-Usage">>, trunk_usage(j5_request:reseller_id(Request))}
             ,{<<"Outbound-Flags">>, OutboundFlags}
             ,{<<"To">>, j5_request:number(Request)}
             ]),

    Resp = props:filter_undefined(
             [{<<"Is-Authorized">>, j5_request:is_authorized(Request)}
             ,{<<"Account-ID">>, j5_request:account_id(Request)}
             ,{<<"Account-Billing">>, j5_request:account_billing(Request)}
             ,{<<"Reseller-ID">>, j5_request:reseller_id(Request)}
             ,{<<"Reseller-Billing">>, j5_request:reseller_billing(Request)}
             ,{<<"Call-Direction">>, j5_request:call_direction(Request)}
             ,{<<"Other-Leg-Call-ID">>, j5_request:other_leg_call_id(Request)}
             ,{<<"Soft-Limit">>, j5_request:soft_limit(Request)}
             ,{<<"Msg-ID">>, j5_request:message_id(Request)}
             ,{<<"Call-ID">>, j5_request:call_id(Request)}
             ,{<<"Custom-Channel-Vars">>, CCVs}
             | kz_api:default_headers(?APP_NAME, ?APP_VERSION)
             ]),
    kapi_authz:publish_authz_resp(ServerId, Resp),
    j5_util:maybe_send_system_alert(Request),
    kapi_authz:broadcast_authz_resp(Resp).

-spec trunk_usage(kz_term:ne_binary()) -> kz_term:ne_binary().
trunk_usage(<<Id/binary>>) ->
    Limits = j5_limits:get(Id),
    <<(kz_term:to_binary(j5_limits:inbound_trunks(Limits)))/binary, "/"
     ,(kz_term:to_binary(j5_limits:outbound_trunks(Limits)))/binary, "/"
     ,(kz_term:to_binary(j5_limits:twoway_trunks(Limits)))/binary, "/"
     ,(kz_term:to_binary(j5_limits:burst_trunks(Limits)))/binary, "/"
     ,(kz_term:to_binary(j5_channels:inbound_flat_rate(Id)))/binary, "/"
     ,(kz_term:to_binary(j5_channels:outbound_flat_rate(Id)))/binary
    >>.
