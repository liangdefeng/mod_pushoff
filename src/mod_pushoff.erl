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
         offline_message/1, adhoc_local_commands/4, remove_user/2,
         health/0]).

-include("logger.hrl").
-include("xmpp.hrl").
-include("adhoc.hrl").

-include("mod_pushoff.hrl").

-define(OFFLINE_HOOK_PRIO, 1). % must fire before mod_offline (which has 50)
-define(ALERT, "alert").
-define(VOIP, "voip").

-type apns_config() :: #{backend_type := mod_pushoff_apns_h2, certfile := binary(), gateway := binary(), topic := binary()}.
-type fcm_config() :: #{backend_type := mod_pushoff_fcm, gateway := binary(), api_key := binary()}.
-type backend_config() :: #{ref := backend_ref(), config := apns_config() | fcm_config()}.

%
% dispatch to workers
%

-spec(stanza_to_payload(message()) -> [{atom(), any()}]).
stanza_to_payload(#message{id = Id, sub_els = SubEls } = Msg) ->
  PushType = case fxml:get_subtag(#xmlel{ children = SubEls }, <<"push">>) of
    false -> [];
    PushTag = #xmlel{} ->
      case fxml:get_tag_attr_s(<<"type">>, PushTag) of
        <<"hidden">> -> [
          {push_type, hidden},
          {apns_push_type, ?ALERT}
        ];
        <<"call">> -> [
          {push_type, call},
          {apns_push_type, ?VOIP}
        ];
        <<"none">> -> [
          {push_type, none},
          {apns_push_type, ?ALERT}
        ];
        <<"message">> -> [
            {push_type, message},
            {apns_push_type, ?ALERT},
            {from, jid:to_string(Msg#message.from)}
          ];
        <<"body">> -> [
            {push_type, body},
            {body, Msg#message.body},
            {apns_push_type, ?ALERT},
            {from, jid:to_string(Msg#message.from)}
          ];
        _ -> []
      end
  end,
  [{id, Id} | PushType];
stanza_to_payload(_) -> [].

-spec(dispatch(pushoff_registration(), [{atom(), any()}]) -> ok).

dispatch(#pushoff_registration{key = Key, token = Token, timestamp = Timestamp, backend_id = BackendId}, Payload) ->
  ?DEBUG("dispatch#start",[]),
  DisableArgs = {Key, Timestamp},
  gen_server:cast(backend_worker(BackendId), {dispatch, Key, Payload, Token, DisableArgs}),
  ok.


%
% ejabberd hooks
%

-spec(offline_message({atom(), message()}) -> {atom(), message()}).
offline_message({_, #message{to = To} = Stanza} = Acc) ->
  ?DEBUG("offline_message#start",[]),
  Payload = stanza_to_payload(Stanza),
  case proplists:get_value(push_type, Payload, none) of
    none ->
      ok;
    call ->
      Key = {To#jid.luser, To#jid.lserver, voip},
      case mod_pushoff_mnesia:list_registrations(Key) of
        {registrations, []} ->
          ?DEBUG("~p is not_subscribed", [To]),
          ok;
        {registrations, Rs} ->
          [dispatch(R, Payload) || R <- Rs],
          ok;
        {error, _} -> ok
      end;
    _ ->
      Key = {To#jid.luser, To#jid.lserver},
      case mod_pushoff_mnesia:list_registrations(Key) of
        {registrations, []} ->
          ?DEBUG("~p is not_subscribed", [To]),
          ok;
        {registrations, Rs} ->
          [dispatch(R, Payload) || R <- Rs],
          ok;
        {error, _} -> ok
      end
  end,
  Acc.

-spec(remove_user(User :: binary(), Server :: binary()) ->
  {error, stanza_error()} |{unregistered, [pushoff_registration()]}).
remove_user(User, Server) ->
  mod_pushoff_mnesia:unregister_client({User, Server}, '_').

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
        allow -> adhoc_perform_action(Command, From, XData)
    end,

    case Result of
        unknown -> Acc;
        {error, Error} -> {error, Error};
        {registered, ok} ->
            xmpp_util:make_adhoc_response(Req, #adhoc_command{status = completed});

        {unregistered, Regs} ->
            X = xmpp_util:set_xdata_field(#xdata_field{var = <<"removed-registrations">>,
                                                       values = [T || #pushoff_registration{token=T} <- Regs]}, #xdata{}),
            xmpp_util:make_adhoc_response(Req, #adhoc_command{status = completed, xdata = X});

        {registrations, Regs} ->
            X = xmpp_util:set_xdata_field(#xdata_field{var = <<"registrations">>,
                                                       values = [T || #pushoff_registration{token=T} <- Regs]}, #xdata{}),
            xmpp_util:make_adhoc_response(Req, #adhoc_command{status = completed, xdata = X})
    end;
adhoc_local_commands(Acc, _From, _To, _Request) ->
    Acc.


adhoc_perform_action(<<"register-push-apns-h2">>, #jid{lserver = LServer} = From, XData) ->
    BackendRef = case xmpp_util:get_xdata_values(<<"backend_ref">>, XData) of
        [Key] -> {mod_pushoff_apns_h2, Key};
        _ -> undefined
    end,
    case validate_backend_ref(LServer, BackendRef) of
        {error, E} -> {error, E};
        {ok, BackendRef} ->
            case xmpp_util:get_xdata_values(<<"token">>, XData) of
                [Base64Token] ->
                    case catch base64:decode(Base64Token) of
                        {'EXIT', _} -> {error, xmpp:err_bad_request()};
                        Token ->
                          Key2 = {From#jid.luser, From#jid.lserver},
                          mod_pushoff_mnesia:register_client(Key2, {LServer, BackendRef}, Token)
                    end;
                _ -> {error, xmpp:err_bad_request()}
            end
    end;
adhoc_perform_action(<<"register-push-apns-h2-voip">>, #jid{lserver = LServer} = From, XData) ->
  BackendRef = case xmpp_util:get_xdata_values(<<"backend_ref">>, XData) of
                 [Key] -> {mod_pushoff_apns_h2, Key};
                 _ -> undefined
               end,
  case validate_backend_ref(LServer, BackendRef) of
    {error, E} -> {error, E};
    {ok, BackendRef} ->
      case xmpp_util:get_xdata_values(<<"token">>, XData) of
        [Base64Token] ->
          case catch base64:decode(Base64Token) of
            {'EXIT', _} -> {error, xmpp:err_bad_request()};
            Token ->
              Key2 = {{From#jid.luser, server = From#jid.server}, voip},
              mod_pushoff_mnesia:register_client(Key2, {LServer, BackendRef}, Token)
          end;
        _ -> {error, xmpp:err_bad_request()}
      end
  end;
adhoc_perform_action(<<"register-push-apns">>, #jid{lserver = LServer} = From, XData) ->
    BackendRef = case xmpp_util:get_xdata_values(<<"backend_ref">>, XData) of
        [Key] -> {mod_pushoff_apns, Key};
        _ -> mod_pushoff_apns
    end,
    case validate_backend_ref(LServer, BackendRef) of
        {error, E} -> {error, E};
        {ok, BackendRef} ->
            case xmpp_util:get_xdata_values(<<"token">>, XData) of
                [Base64Token] ->
                    case catch base64:decode(Base64Token) of
                        {'EXIT', _} -> {error, xmpp:err_bad_request()};
                        Token ->
                          Key2 = #jid{user = From#jid.user, server = From#jid.server},
                          mod_pushoff_mnesia:register_client(Key2, {LServer, BackendRef}, Token)
                    end;
                _ -> {error, xmpp:err_bad_request()}
            end
    end;
adhoc_perform_action(<<"register-push-apns-voip">>, #jid{lserver = LServer} = From, XData) ->
  BackendRef = case xmpp_util:get_xdata_values(<<"backend_ref">>, XData) of
                 [Key] -> {mod_pushoff_apns, Key};
                 _ -> mod_pushoff_apns
               end,
  case validate_backend_ref(LServer, BackendRef) of
    {error, E} -> {error, E};
    {ok, BackendRef} ->
      case xmpp_util:get_xdata_values(<<"token">>, XData) of
        [Base64Token] ->
          case catch base64:decode(Base64Token) of
            {'EXIT', _} -> {error, xmpp:err_bad_request()};
            Token ->
              Key2 = {From#jid.luser, From#jid.lserver, voip},
              mod_pushoff_mnesia:register_client(Key2, {LServer, BackendRef}, Token)
          end;
        _ -> {error, xmpp:err_bad_request()}
      end
  end;
adhoc_perform_action(<<"register-push-fcm">>, #jid{lserver = LServer} = From, XData) ->
    BackendRef = case xmpp_util:get_xdata_values(<<"backend_ref">>, XData) of
        [Key] -> {fcm, Key};
        _ -> fcm
    end,
    case validate_backend_ref(LServer, BackendRef) of
        {error, E} -> {error, E};
        {ok, BackendRef} ->
            case xmpp_util:get_xdata_values(<<"token">>, XData) of
                [AsciiToken] ->
                  Key2 = {From#jid.luser, From#jid.lserver},
                  mod_pushoff_mnesia:register_client(Key2, {LServer, BackendRef}, AsciiToken);
                _ -> {error, xmpp:err_bad_request()}
            end
    end;
adhoc_perform_action(<<"unregister-push">>, From, _) ->
  mod_pushoff_mnesia:unregister_client(From, undefined);
adhoc_perform_action(<<"list-push-registrations">>, From, _) ->
  mod_pushoff_mnesia:list_registrations_all({From#jid.luser, From#jid.lserver});
adhoc_perform_action(_, _, _) ->
    unknown.

%
% ejabberd gen_mod callbacks and configuration
%

-spec(start(Host :: binary(), Opts :: [any()]) -> any()).

start(Host, Opts) ->
    mod_pushoff_mnesia:create(),

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
mod_opt_type(backends) ->
    econf:list(
        backend()
    );
mod_opt_type(access_backends) ->
    econf:acl();
mod_opt_type(_) -> [backends, access_backends].

mod_options(_Host) ->
    [{backends, []},
     {access_backends, all}].

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

%
% operations
%

health() ->
    Hosts = ejabberd_config:get_myhosts(),
    [{offline_message_hook, [ets:lookup(hooks, {offline_message_hook, H}) || H <- Hosts]},
     {adhoc_local_commands, [ets:lookup(hooks, {adhoc_local_commands, H}) || H <- Hosts]},
     {mnesia, mod_pushoff_mnesia:health()}].
