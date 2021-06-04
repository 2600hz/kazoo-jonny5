-ifndef(JONNY5_HRL).
-include_lib("kazoo_stdlib/include/kz_types.hrl").
-include_lib("kazoo_stdlib/include/kz_log.hrl").
-include_lib("kazoo_stdlib/include/kz_databases.hrl").

-define(CACHE_NAME, 'jonny5_cache').

-define(APP_VERSION, kz_application:application_version('jonny5')).
-define(APP_NAME, <<"jonny5">>).

-type tristate_integer() :: -1 | non_neg_integer().

-define(JONNY5_HRL, 'true').
-endif.
