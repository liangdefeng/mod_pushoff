-module(mod_pushoff_message).
-author("Sergey Loguntsov <loguntsov@gmail.com>").

%% API
-export([
  body/1, title/1, from/1, apns_push_type/1
]).

body(Payload) ->
  proplists:get_value(body, Payload).

title(Payload) ->
  proplists:get_value(title, Payload).

from(Payload) ->
  proplists:get_value(from, Payload, <<>>).

apns_push_type(Payload) ->
  proplists:get_value(apns_push_type, Payload, <<>>).
