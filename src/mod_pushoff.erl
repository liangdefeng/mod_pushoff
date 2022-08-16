%%%
%%% Copyright (C) 2015  Christian Ulrich
%%% Copyright (C) 2016  Vlad Ki
%%%
%%% This program is free software; you can redistribute it and/or
%%% modify it under the terms of the GNU General Public License as
%%% published by the Free Software Foundation; either version 2 of the
%%% License, or (at your option) any later version.
%%%
%%% This program is distributed in the hope that it will be useful,
%%% but WITHOUT ANY WARRANTY; without even the implied warranty of
%%% MERCHANTABILITY or FITNESS FOR A PARTICULAR PURPOSE.  See the GNU
%%% General Public License for more details.
%%%
%%% You should have received a copy of the GNU General Public License along
%%% with this program; if not, write to the Free Software Foundation, Inc.,
%%% 51 Franklin Street, Fifth Floor, Boston, MA 02110-1301 USA.

-module(mod_pushoff).

-author('christian@rechenwerk.net').
-author('proger@wilab.org.ua').
-author('dimskii123@gmail.com').
-author('defeng.liang.cn@gmail.com').

-behaviour(gen_mod).

-compile(export_all).
-export([start/2, stop/1, reload/3, depends/2, mod_options/1, mod_opt_type/1, parse_backends/1,
         offline_message/1, adhoc_local_commands/4, remove_user/2, unregister_client/1,
         health/0]).

-include("logger.hrl").
-include("xmpp.hrl").
-include("adhoc.hrl").

-include("mod_pushoff.hrl").

-define(OFFLINE_HOOK_PRIO, 1). % must fire before mod_offline (which has 50)
-define(ALERT, "alert").
-define(VOIP, "voip").

-define(OMEMO_ENCRYPTED_MESSAGE, <<73,32, 115,101,110,116,32,121,111,117,32,97,110,32,79,77,69,77,79,32,101,110,99,
  114,121,112,116,101,100,32,109,101,115,115,97,103,101,32,98,117,116,32,121,111,117,114,32,99,108,105,101,110,116,
  32,100,111,101,115,110,226,128,153,116,32,115,101,101,109,32,116,111,32,115,117,112,112,111,114,116,32,116,104,97,
  116,46>>).

-define(NORMAL_PUSH_TYPE, 0).
-define(VOIP_PUSH_TYPE, 1).

-type apns_config() :: #{backend_type := mod_pushoff_apns_curl, path := binary(), topic := binary()}.
-type fcm_config() :: #{backend_type := mod_pushoff_fcm, gateway := binary(), api_key := binary()}.
-type backend_config() :: #{ref := backend_ref(), config := apns_config() | fcm_config()}.

%
% dispatch to workers
%

stanza_to_payload(MsgId, FromUser, DataMap) ->
  MsgTypeStr = maps:get(type, DataMap, <<"">>),
  StatusStr = maps:get(status, DataMap, <<"">>),
  Sender = maps:get(sender, DataMap, <<"">>),
  RoomId = maps:get(roomid, DataMap, <<"">>),
  Time = maps:get(time, DataMap, <<"">>),

  MsgType = case is_atom(MsgTypeStr) of
    true ->
      MsgTypeStr;
    _ ->
      binary_to_atom(MsgTypeStr, unicode)
  end,

  Status = binary_to_atom(StatusStr, unicode),
  PushType = case get_msg_type(MsgType, Status) of
              call -> [
                {push_type, voip},
                {roomid, RoomId},
                {type, MsgTypeStr},
                {status, StatusStr},
                {sender, Sender},
                {time, Time},
                {apns_push_type, ?VOIP}
              ];
              message -> [
                {push_type, message},
                {apns_push_type, ?ALERT},
                {title, get_title(MsgType, Status, FromUser)},
                {from, FromUser}
              ];
              body -> [
                {push_type, body},
                {apns_push_type, ?ALERT},
                {title, get_title(MsgType, Status, FromUser)},
                {from, FromUser}
              ];
              _ -> []
             end,
  [{id, MsgId} | PushType];
stanza_to_payload(_MsgId, _FromUser, _DataMap) -> [].

get_msg_type(_, start) ->
  call;
get_msg_type(_, _) ->
  message.

-spec(dispatch(pushoff_registration(), [{atom(), any()}]) -> ok).

dispatch(#pushoff_registration{key = Key, token = Token, timestamp = Timestamp, backend_id = BackendId}, Payload) ->
  DisableArgs = {Key, Timestamp},
  gen_server:cast(backend_worker(BackendId), {dispatch, Key, Payload, Token, DisableArgs}),
  ok.

is_muc(From) ->
  #jid{lserver = Server}  = From,
  Hosts = [ mod_muc_opt:host(X) || X <- ejabberd_option:hosts() ],
  lists:member(Server, Hosts).

get_room_title(From) ->
  #jid {luser = RoomId, lserver = Server}  = From,
  TupleList = mod_muc_admin:get_room_options(RoomId,Server),
  case lists:keyfind(<<"title">>, 1, TupleList) of
    {_, Title} ->
      binary_to_list(Title);
    _ ->
      ""
  end.

user_send_packet({#message{to = To, from = From, id = Id} = Stanza, _} = Acc) ->
  ?DEBUG("user_send_packet START",[]),
  case xmpp:try_subtag(Stanza, #push_notification{}) of
    false ->
      ok;
    #push_notification{xdata = #xdata{fields = Fields}} ->
      ?DEBUG("Fields is ~p~n",[Fields]),
      #jid{user = FromUser} = From,
      FieldMap = fields_to_map(Fields),

      case {maps:get(type, FieldMap, <<"">>), maps:get(status, FieldMap, <<"">>)} of
        {<<"voice">>, <<"start">>} ->
          ?DEBUG("Sending notification",[]),
          send_notification(Id, binary_to_list(FromUser), To, FieldMap);
        {<<"video">>, <<"start">>} ->
          ?DEBUG("Sending notification",[]),
          send_notification(Id, binary_to_list(FromUser), To, FieldMap);
        _ ->
          ok
      end
  end,
  Acc;
user_send_packet(Acc) ->
  Acc.

%
% ejabberd hooks
%
-spec(offline_message({atom(), message()}) -> {atom(), message()}).
offline_message({_, #message{to = To,
  from = From, id = Id, body = [#text{data = Data}] = Body} = Stanza} = Acc) ->
  ?DEBUG("Stanza is ~p~n",[Stanza]),
  case string:slice(Data, 0, 19) of
    <<"aesgcm://w-4all.com">> -> %% Messages start with aesgcm are video or voice messages.
      ok;
    _ ->
      case is_muc(From) of
        true ->
          FromResource = From#jid.lresource,
          RoomTitle = get_room_title(From),
          FromUser = binary_to_list(FromResource) ++ " group " ++  RoomTitle,
          DataList = [{type, offine}, {status, <<"missed">>}, {body, Data}],
          FieldMap = maps:from_list(DataList),
          send_notification(Id, FromUser, To, FieldMap);
        _ ->
          case Body of
            [] ->
              ok;
            _ ->
              #jid{user = FromUser} = From,
              DataList = [{type, offine}, {status, <<"missed">>}, {body, Data}],
              FieldMap = maps:from_list(DataList),
              send_notification(Id, binary_to_list(FromUser), To, FieldMap)
          end
      end
  end,
  Acc;
offline_message({_, #message{to = To, from = From, id = Id} = Stanza} = Acc) ->
  case xmpp:try_subtag(Stanza, #push_notification{}) of
    false ->
      ok;
    #push_notification{xdata = #xdata{fields = Fields}} ->
      ?DEBUG("Fields is ~p~n",[Fields]),
      #jid{user = FromUser} = From,
      FieldMap = fields_to_map(Fields),
      send_notification(Id, binary_to_list(FromUser), To, FieldMap)

  end,
  Acc;
offline_message(Acc) ->
  Acc.

fields_to_map(Fields) ->
  maps:from_list(
    lists:filtermap(
      fun(Item) ->
        case Item of
          #xdata_field{var = Var, values=[Values]} ->
            {true, {binary_to_atom(Var, unicode), Values}};
          _ ->
            false
        end
      end, Fields)).


send_notification(MsgId, FromUser, To, DataMap) ->

  Payload = stanza_to_payload(MsgId, FromUser, DataMap),
  case proplists:get_value(push_type, Payload, none) of
    none ->
      ok;
    voip ->
      LServer = To#jid.lserver,
      Key = {To#jid.luser, To#jid.lserver, ?VOIP_PUSH_TYPE},
      Mod = gen_mod:db_mod(LServer, ?MODULE),
      case Mod:list_registrations(Key) of
        {registrations, []} ->
          ?DEBUG("~p is not_subscribed", [To]),
          ok;
        {registrations, Rs} ->
          [dispatch(R, Payload) || R <- Rs],
          ok;
        {error, _} -> ok
      end;
    _ ->
      LServer = To#jid.lserver,
      Key = {To#jid.luser, To#jid.lserver, ?NORMAL_PUSH_TYPE},
      Mod = gen_mod:db_mod(LServer, ?MODULE),
      case Mod:list_registrations(Key) of
        {registrations, []} ->
          ?DEBUG("~p is not_subscribed", [To]),
          ok;
        {registrations, Rs} ->
          ?DEBUG("Rs:~p~n",[Rs]),
          [dispatch(R, Payload) || R <- Rs],
          ok;
        {error, _} -> ok
      end
  end,
  ok.

-spec(unregister_client({key(), erlang:timestamp()}) ->
  {error, stanza_error()} |
  {unregistered, [pushoff_registration()]}).
unregister_client({Key, _Timestamp}) ->
  {User, Server, _PushType} = Key,
  Mod = gen_mod:db_mod(Server, ?MODULE),
  Mod:unregister_client(User, Server).

-spec(remove_user(User :: binary(), Server :: binary()) ->
  {error, stanza_error()} |{unregistered, [pushoff_registration()]}).
remove_user(User, Server) ->
  Mod = gen_mod:db_mod(Server, ?MODULE),
  Mod:unregister_client(User, Server).

-spec adhoc_local_commands(Acc :: empty | adhoc_command(),
                           From :: jid(),
                           To :: jid(),
                           Request :: adhoc_command()) ->
                                  adhoc_command() |
                                  {error, stanza_error()}.
adhoc_local_commands(Acc, From, To, #adhoc_command{node = Command, action = execute, xdata = XData} = Req) ->
    Host = To#jid.lserver,
    Access = gen_mod:get_module_opt(Host, ?MODULE, access_backends),
    Result = case acl:match_rule(Host, Access, From) of
        deny -> {error, xmpp:err_forbidden()};
        allow ->
          adhoc_perform_action(Command, From, XData)
    end,
    case Result of
        unknown -> Acc;
        {error, Error} -> {error, Error};
        {registered, ok} ->
            xmpp_util:make_adhoc_response(Req, #adhoc_command{status = completed});

        {unregistered, Regs} ->
            X = xmpp_util:set_xdata_field(#xdata_field{
              var = <<"removed-registrations">>,
              options = [ #xdata_option{label = L, value = T}
                || #pushoff_registration{token=T, backend_ref = L} <- Regs]},
              #xdata{}),
            xmpp_util:make_adhoc_response(Req, #adhoc_command{status = completed, xdata = X});
        {registrations, Regs} ->
            X = xmpp_util:set_xdata_field(#xdata_field{
              var = <<"registrations">>,
              options = [ #xdata_option{label = L, value = T}
                || #pushoff_registration{token=T, backend_ref = L} <- Regs]},
              #xdata{}),
            xmpp_util:make_adhoc_response(Req, #adhoc_command{status = completed, xdata = X})
    end;
adhoc_local_commands(Acc, _From, _To, _Request) ->
    Acc.


adhoc_perform_action(<<"register-push-apns">>, #jid{lserver = LServer} = From, XData) ->
    BackendRef = case xmpp_util:get_xdata_values(<<"backend_ref">>, XData) of
        [Key] -> {mod_pushoff_apns_curl, Key};
        _ -> {mod_pushoff_apns_curl, <<"apn">>}
    end,

    case validate_backend_ref(LServer, BackendRef) of
        {error, E} -> {error, E};
        {ok, BackendRef} ->
            case xmpp_util:get_xdata_values(<<"token">>, XData) of
                [Base64Token] ->
                  Key2 = {From#jid.luser, From#jid.lserver, ?NORMAL_PUSH_TYPE},
                  Mod = gen_mod:db_mod(LServer, ?MODULE),
                  Mod:register_client(Key2, {LServer, BackendRef}, Base64Token);
                _ ->
                  {error, xmpp:err_bad_request()}
            end
    end;
adhoc_perform_action(<<"register-push-apns-voip">>, #jid{lserver = LServer} = From, XData) ->
  BackendRef = case xmpp_util:get_xdata_values(<<"backend_ref">>, XData) of
                 [Key] -> {mod_pushoff_apns_curl, Key};
                 _ -> {mod_pushoff_apns_curl, <<"voip">>}
               end,
  case validate_backend_ref(LServer, BackendRef) of
    {error, E} -> {error, E};
    {ok, BackendRef} ->
      case xmpp_util:get_xdata_values(<<"token">>, XData) of
        [Base64Token] ->
          Key2 = {From#jid.luser, From#jid.server, ?VOIP_PUSH_TYPE},
          Mod = gen_mod:db_mod(LServer, ?MODULE),
          Mod:register_client(Key2, {LServer, BackendRef}, Base64Token);
        _ ->
          {error, xmpp:err_bad_request()}
      end
  end;
adhoc_perform_action(<<"register-push-fcm">>, #jid{lserver = LServer} = From, XData) ->
    BackendRef = case xmpp_util:get_xdata_values(<<"backend_ref">>, XData) of
        [Key] -> {fcm, Key};
        _ -> {fcm,<<"fcm">>}
    end,
    case validate_backend_ref(LServer, BackendRef) of
        {error, E} -> {error, E};
        {ok, BackendRef} ->
            case xmpp_util:get_xdata_values(<<"token">>, XData) of
                [AsciiToken] ->
                  Key2 = {From#jid.luser, From#jid.lserver, ?NORMAL_PUSH_TYPE},
                  Mod = gen_mod:db_mod(LServer, ?MODULE),
                  Mod:register_client(Key2, {LServer, BackendRef}, AsciiToken);
                _ -> {error, xmpp:err_bad_request()}
            end
    end;
adhoc_perform_action(<<"unregister-push">>, #jid{lserver = LServer} = From, _) ->
  Mod = gen_mod:db_mod(LServer, ?MODULE),
  Mod:unregister_client(From#jid.luser, From#jid.lserver);
adhoc_perform_action(<<"list-push-registrations">>, #jid{lserver = LServer} = From, _) ->
  Mod = gen_mod:db_mod(LServer, ?MODULE),
  Mod:list_registrations_all({From#jid.luser, From#jid.lserver});
adhoc_perform_action(_, _, _) ->
  unknown.

%
% ejabberd gen_mod callbacks and configuration
%

-spec(start(Host :: binary(), Opts :: [any()]) -> any()).

start(Host, Opts) ->
    ok = ejabberd_hooks:add(user_send_packet,Host, ?MODULE, user_send_packet, 30),
    ok = ejabberd_hooks:add(remove_user, Host, ?MODULE, remove_user, 50),
    ok = ejabberd_hooks:add(offline_message_hook, Host, ?MODULE, offline_message, ?OFFLINE_HOOK_PRIO),
    ok = ejabberd_hooks:add(adhoc_local_commands, Host, ?MODULE, adhoc_local_commands, 75),

    Results = [start_worker(Host, B) || B <- parse_backends(maps:get(backends, Opts))],
    ?INFO_MSG("mod_pushoff workers: ~p", [Results]),
    ok.

-spec(stop(Host :: binary()) -> any()).

stop(Host) ->
    ?DEBUG("mod_pushoff:stop(~p), pid=~p", [Host, self()]),
    ok = ejabberd_hooks:delete(user_send_packet, Host, ?MODULE, user_send_packet, 30),
    ok = ejabberd_hooks:delete(adhoc_local_commands, Host, ?MODULE, adhoc_local_commands, 75),
    ok = ejabberd_hooks:delete(offline_message_hook, Host, ?MODULE, offline_message, ?OFFLINE_HOOK_PRIO),
    ok = ejabberd_hooks:delete(remove_user, Host, ?MODULE, remove_user, 50),

    [begin
         Worker = backend_worker({Host, Ref}),
         supervisor:terminate_child(ejabberd_gen_mod_sup, Worker),
         supervisor:delete_child(ejabberd_gen_mod_sup, Worker)
     end || #{ref := Ref} <- backend_configs(Host)],
    ok.

reload(Host, NewOpts, _OldOpts) ->
    stop(Host),
    start(Host, NewOpts),
    ok.

depends(_, _) ->
    [{mod_offline, hard}, {mod_adhoc, hard}].

% mod_opt_type(backends) -> fun ?MODULE:parse_backends/1;
mod_opt_type(db_type) ->
  econf:db_type(?MODULE);
mod_opt_type(backends) ->
    econf:list(
        backend()
    );
mod_opt_type(access_backends) ->
    econf:acl();
mod_opt_type(_) -> [backends, access_backends].

mod_options(Host) ->
    [
      {db_type, ejabberd_config:default_db(Host, ?MODULE)},
      {backends, []},
      {access_backends, all}
    ].

validate_backend_ref(Host, Ref) ->
    case [R || #{ref := R} <- backend_configs(Host), R == Ref] of
        [R] -> {ok, R};
        _ -> {error, xmpp:err_bad_request()}
    end.

backend_ref(X, undefined) -> X;
backend_ref(X, K) -> {X, K}.

backend_type({Type, _}) -> Type;
backend_type(Type) -> Type.

parse_backends(Plists) ->
    [parse_backend(Plist) || Plist <- Plists].

-spec(parse_backend(proplist:proplist()) -> backend_config()).
parse_backend(Opts) ->
    Ref = backend_ref(proplists:get_value(type, Opts), proplists:get_value(backend_ref, Opts)),
    #{ref => Ref,
      config =>
         case backend_type(Ref) of
           mod_pushoff_fcm ->
             #{backend_type => mod_pushoff_fcm,
               gateway => proplists:get_value(gateway, Opts),
               api_key => proplists:get_value(api_key, Opts)};
           mod_pushoff_apns_curl ->
                 #{backend_type => mod_pushoff_apns_curl,
                   path => proplists:get_value(path, Opts),
                   topic => proplists:get_value(topic, Opts)};
           X ->
             #{backend_type => mod_pushoff_apns_curl,
               path => proplists:get_value(path, Opts),
               topic => proplists:get_value(topic, Opts)}
         end}.

% -spec backend() -> yconf:validator(jid:jid()).
backend() ->
    econf:and_then(
        econf:list(econf:any()),
        fun(Val) ->
            case parse_backend(Val) of
                #{ config := _ } ->
                    Val;
                _ ->
                    econf:fail(Val)
            end
        end). 


%
% workers
%

-spec(backend_worker(backend_id()) -> atom()).

backend_worker({Host, {T, R}}) ->
  gen_mod:get_module_proc(Host, binary_to_atom(<<(erlang:atom_to_binary(T, latin1))/binary, "_", R/binary>>, latin1));
backend_worker({Host, Ref}) ->
  gen_mod:get_module_proc(Host, Ref).

backend_configs(Host) ->
    parse_backends(gen_mod:get_module_opt(Host, ?MODULE, backends)).

-spec(start_worker(Host :: binary(), Backend :: backend_config()) -> ok).

start_worker(Host, #{ref := Ref, config := Config}) ->
    Worker = backend_worker({Host, Ref}),
    BackendSpec = {Worker,
                   {gen_server, start_link,
                    [{local, Worker}, backend_type(Ref), Config, []]},
                   permanent, 1000, worker, [?MODULE]},
    supervisor:start_child(ejabberd_gen_mod_sup, BackendSpec).

mod_doc() ->
  #{}.
%
% operations
%

health() ->
    Hosts = ejabberd_config:get_myhosts(),
    [{offline_message_hook, [ets:lookup(hooks, {offline_message_hook, H}) || H <- Hosts]},
     {adhoc_local_commands, [ets:lookup(hooks, {adhoc_local_commands, H}) || H <- Hosts]}].

get_title(voice, start, FromUser) ->
  "voice call from " ++ FromUser;
get_title(video, start, FromUser) ->
  "Video call from " ++ FromUser;
get_title(voice, missed, FromUser) ->
  "Missed a voice call from " ++ FromUser;
get_title(video, missed, FromUser) ->
  "Missed a video call from " ++ FromUser;
get_title(location, _, FromUser) ->
  "Location message from " ++ FromUser;
get_title(photo, _, FromUser) ->
  "Photo message from " ++ FromUser;
get_title(files, _, FromUser) ->
  "File message from " ++ FromUser;
get_title(voice, _, FromUser) ->
  "Voice message from " ++ FromUser;
get_title(video, _, FromUser) ->
  "Video message from " ++ FromUser;
get_title(_, _, FromUser) ->
  "Text message from " ++ FromUser.

get_body(Body) ->
  NewBody = mod_pushoff_utils:force_string(Body),
  [Data2 | _Rest] = string:split(NewBody, "\n"),
  Len = string:length(Data2),
  if Len > 15 ->
      string:slice(Data2,0,15) ++ "...";
    true ->
      Data2
  end.
