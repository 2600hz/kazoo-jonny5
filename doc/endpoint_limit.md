# Endpoint Limit

**NOTE**: This functionality is only meant to be used for endpoints with a limitation already set,
it does not work for devices without limitation.

This new functionality allows to keep track of concurrent calls per endpoint by exposing an API to
`reserve`, `release`, and list `reservations`.

The way this restriction works is, when a request to create a new reservation is made, the code will
get the maximum concurrent calls limit for the given endpoint and will count the current numbers of
reservations for this endpoint and will compare it with its limit. If current number of reservations
is lower than the limit, it creates a new reservation for the endpoint and returns a tuple in the
form `{ok, reservation_id, current_reservations_count, available_reservations_count}`. If limit was
reached, the reservation will be denied and a tuple in the form `{error, 486}` will be returned.

Let us take a look at an example. For this example, *AccountId* and *EndpointId* existence
is assumed, as well as a limitation of 2 maximum concurrent calls per endpoint.

```erlang
AccounId = <<"account012345">>,
EndpointId = <<"user543210">>,

%% Creating reservations
{ok, ReservationId0, 1, 1} = j5_endpoint_limit_ra:reserve(AccountId, EndpointId),
{ok, ReservationId1, 2, 0} = j5_endpoint_limit_ra:reserve(AccountId, EndpointId),
{error, 486} = j5_endpoint_limit_ra:reserve(AccountId, UserId),  %% Because limit was reached.

%% Listing reservations can be done per:
%% - All the reservations
{ok, #{AccountId := #{EndpointId := #{'uuids' := [ReservationId1, ReservationId0]
                                     ,'limit' := 2
                                     }}}} = j5_endpoint_limit_ra:reservations(),
%% - Reservations per account
{ok, #{EndpointId := #{'uuids' := [ReservationId1, ReservationId0]
                      ,'limit' := 2
                      }}} = j5_endpoint_limit_ra:reservations(AccountId),
%% - Reservations per account->endpoint_id
{ok, [ReservationId1, ReservationId0]} = j5_endpoint_limit_ra:reservations(AccountId, EndpointId),

%% Releasing reservations
{ok, 1, 1} = j5_endpoint_limit_ra:release(ReservationId0),
{ok, 0, 2} = j5_endpoint_limit_ra:release(ReservationId1).
```
