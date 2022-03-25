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

-define(NORMAL_PUSH_TYPE, 0).
-define(VOIP_PUSH_TYPE, 1).

-type apns_config() :: #{backend_type := mod_pushoff_apns_h2, certfile := binary(), gateway := binary(), topic := binary()}.
-type fcm_config() :: #{backend_type := mod_pushoff_fcm, gateway := binary(), api_key := binary()}.
-type backend_config() :: #{ref := backend_ref(), config := apns_config() | fcm_config()}.

%
% dispatch to workers
%

stanza_to_payload(MsgId, MsgType, MsgStatus, FromUser, Data) ->
  PushType = case get_msg_type(MsgType,MsgStatus) of
              call -> [
                  {push_type, call},
                  {apns_push_type, ?VOIP}
                ];
              message -> [
                {push_type, message},
                {apns_push_type, ?ALERT},
                {title, get_title(MsgType, MsgStatus, FromUser)},
                {from, FromUser}
              ];
              body -> [
                {push_type, body},
                {apns_push_type, ?ALERT},
                {title, get_title(MsgType, MsgStatus, FromUser)},
                {body, get_body(Data)},
                {from, FromUser}
              ];
              _ -> []
             end,
  [{id, MsgId} | PushType];
stanza_to_payload(_MsgId, _MsgType, _MsgStatus, _FromUser, _Data) -> [].

get_msg_type(MsgType,MsgStatus) ->
  case {MsgType,MsgStatus} of
    {voice, start} -> call;
    {video, start} -> call;
    {location, _} -> message;
    {photo, _} -> message;
    {files, _} -> message;
    {video, _} -> message;
    {voice, _} -> message;
    {_, _} -> body
  end.

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

%
% ejabberd hooks
%
-spec(offline_message({atom(), message()}) -> {atom(), message()}).
offline_message({_, #message{to = To,
  from = From, id = Id, body = [#text{data = Data}] = Body} = Stanza} = Acc) ->
  ?DEBUG("Stanza:~p~n",[Stanza]),
  case string:slice(Data, 0, 19) of
    <<"aesgcm://w-4all.com">> -> %% Messages start with aesgcm are video or voice messages.
      ok;
    _ ->
      case is_muc(From) of
        true ->
          FromResource = From#jid.lresource,
          RoomTitle = get_room_title(From),
          FromUser = binary_to_list(FromResource) ++ " group " ++  RoomTitle,
          send_notification(Id, FromUser, To, Data, offline, missed);
        _ ->
          case Body of
            [] ->
              ok;
            _ ->
              #jid{user = FromUser} = From,
              send_notification(Id, binary_to_list(FromUser), To, Data, offline, missed)
          end
      end
  end,
  Acc;
offline_message({_, #message{to = #jid{lserver = LServer} = To,
  from = From, id = Id} = Stanza} = Acc) ->
  case xmpp:try_subtag(Stanza, #push_notification{}) of
    false ->
      ok;
    Record ->
      case Record of
        #push_notification{xdata = #xdata{fields = [#xdata_field{var = <<"type">>, values=[Type]},
          #xdata_field{var = <<"message">>, values = [MsgBinary]}]}} ->
          Type2 = binary_to_atom(string:lowercase(Type), unicode),
          #jid{user = FromUser} = From,
          send_notification(Id, binary_to_list(FromUser), To, MsgBinary, Type2, ok);

        #push_notification{xdata = #xdata{fields = [#xdata_field{var = <<"type">>, values=[Type]},
          #xdata_field{var = <<"status">>, values = [StatusBinary]}]}} ->

          Status = binary_to_atom(string:lowercase(StatusBinary), unicode),
          case Status of
            start ->
              ?DEBUG("Status is start, do nothing when user offline.~n",[]),
              ok;
            _ ->
              ?DEBUG("Status is not start, send offfline notification.~n",[]),
              Type2 = binary_to_atom(string:lowercase(Type), unicode),
              #jid{user = FromUser} = From,
              send_notification(Id, binary_to_list(FromUser), To, <<>>, Type2, Status)
          end;
        _ ->
          ok
      end
  end,
  Acc.

send_notification(MsgId, FromUser, To, Data, MsgType, MsgStatus) ->
  Payload = stanza_to_payload(MsgId, MsgType, MsgStatus, FromUser, Data),
  case proplists:get_value(push_type, Payload, none) of
    none ->
      ok;
    call ->
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
        [Key] -> {mod_pushoff_apns_h2, Key};
        _ -> {mod_pushoff_apns_h2, <<"apn">>}
    end,

    case validate_backend_ref(LServer, BackendRef) of
        {error, E} -> {error, E};
        {ok, BackendRef} ->
            case xmpp_util:get_xdata_values(<<"token">>, XData) of
                [Base64Token] ->
                    case catch base64:decode(Base64Token) of
                        {'EXIT', _} -> {error, xmpp:err_bad_request()};
                        _Token ->
                          Key2 = {From#jid.luser, From#jid.lserver, ?NORMAL_PUSH_TYPE},
                          Mod = gen_mod:db_mod(LServer, ?MODULE),
                          Mod:register_client(Key2, {LServer, BackendRef}, Base64Token)
                    end;
                _ -> {error, xmpp:err_bad_request()}
            end
    end;
adhoc_perform_action(<<"register-push-apns-voip">>, #jid{lserver = LServer} = From, XData) ->
  BackendRef = case xmpp_util:get_xdata_values(<<"backend_ref">>, XData) of
                 [Key] -> {mod_pushoff_apns_h2, Key};
                 _ -> {mod_pushoff_apns_h2, <<"voip">>}
               end,
  case validate_backend_ref(LServer, BackendRef) of
    {error, E} -> {error, E};
    {ok, BackendRef} ->
      case xmpp_util:get_xdata_values(<<"token">>, XData) of
        [Base64Token] ->
          case catch base64:decode(Base64Token) of
            {'EXIT', _} -> {error, xmpp:err_bad_request()};
            _Token ->
              Key2 = {From#jid.luser, From#jid.server, ?VOIP_PUSH_TYPE},
              Mod = gen_mod:db_mod(LServer, ?MODULE),
              Mod:register_client(Key2, {LServer, BackendRef}, Base64Token)
          end;
        _ -> {error, xmpp:err_bad_request()}
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
    ok = ejabberd_hooks:add(remove_user, Host, ?MODULE, remove_user, 50),
    ok = ejabberd_hooks:add(offline_message_hook, Host, ?MODULE, offline_message, ?OFFLINE_HOOK_PRIO),
    ok = ejabberd_hooks:add(adhoc_local_commands, Host, ?MODULE, adhoc_local_commands, 75),

    Results = [start_worker(Host, B) || B <- parse_backends(maps:get(backends, Opts))],
    ?INFO_MSG("mod_pushoff workers: ~p", [Results]),
    ok.

-spec(stop(Host :: binary()) -> any()).

stop(Host) ->
    ?DEBUG("mod_pushoff:stop(~p), pid=~p", [Host, self()]),
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
             X when X == mod_pushoff_apns orelse X == mod_pushoff_apns_h2 ->
                 #{backend_type => X,
                   certfile => proplists:get_value(certfile, Opts),
                   gateway => proplists:get_value(gateway, Opts),
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

backend_worker({Host, {T, R}}) -> gen_mod:get_module_proc(Host, binary_to_atom(<<(erlang:atom_to_binary(T, latin1))/binary, "_", R/binary>>, latin1));
backend_worker({Host, Ref}) -> gen_mod:get_module_proc(Host, Ref).

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
  "Text message from" ++ FromUser.

get_body(Body) ->
  binary_to_list(Body).