-type key() :: {binary(), binary(), integer()}.
-type backend_ref() :: {atom(), binary()}.
-type backend_id() :: {binary(), backend_ref()}.

-record(pushoff_registration, {key :: key(),
                               token :: binary(),
                               backend_id :: backend_id(),
                               backend_ref :: backend_ref(),
                               timestamp :: erlang:timestamp()}).

-type pushoff_registration() :: #pushoff_registration{}.
