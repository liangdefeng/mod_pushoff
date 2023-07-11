%%%-------------------------------------------------------------------
%%% @author peter
%%% @copyright (C) 2022, <COMPANY>
%%% @doc
%%%
%%% @end
%%% Created : 14. Apr 2022 2:47 PM
%%%-------------------------------------------------------------------
-module(mod_pushoff_apns_curl).
-author('defeng.liang.cn@gmail.com').

-mode(compile).
-compile(export_all).

-behaviour(gen_server).

-include("logger.hrl").

%% API
-export([start_link/0]).

%% gen_server callbacks
-export([init/1, handle_call/3, handle_cast/2, handle_info/2, terminate/2,
  code_change/3]).

-define(SERVER, ?MODULE).

-record(state, {path, topic}).

%%%===================================================================
%%% API
%%%===================================================================

%% @doc Spawns the server and registers the local name (unique)
-spec(start_link() ->
  {ok, Pid :: pid()} | ignore | {error, Reason :: term()}).
start_link() ->
  gen_server:start_link({local, ?SERVER}, ?MODULE, [], []).

%%%===================================================================
%%% gen_server callbacks
%%%===================================================================

%% @private
%% @doc Initializes the server
-spec(init(Args :: term()) ->
  {ok, State :: #state{}} | {ok, State :: #state{}, timeout() | hibernate} |
  {stop, Reason :: term()} | ignore).
init(#{backend_type := ?MODULE, path := Path, topic := Topic}) ->
  {ok, #state{path = Path, topic = Topic}}.

%% @private
%% @doc Handling call messages
-spec(handle_call(Request :: term(), From :: {pid(), Tag :: term()},
    State :: #state{}) ->
  {reply, Reply :: term(), NewState :: #state{}} |
  {reply, Reply :: term(), NewState :: #state{}, timeout() | hibernate} |
  {noreply, NewState :: #state{}} |
  {noreply, NewState :: #state{}, timeout() | hibernate} |
  {stop, Reason :: term(), Reply :: term(), NewState :: #state{}} |
  {stop, Reason :: term(), NewState :: #state{}}).
handle_call(_Request, _From, State = #state{}) ->
  {reply, ok, State}.

%% @private
%% @doc Handling cast messages
-spec(handle_cast(Request :: term(), State :: #state{}) ->
  {noreply, NewState :: #state{}} |
  {noreply, NewState :: #state{}, timeout() | hibernate} |
  {stop, Reason :: term(), NewState :: #state{}}).
handle_cast({dispatch, _UserBare, Payload, Token, _DisableArgs},
    #state{path = Path, topic = Topic} = State) ->
  send_notification(Token, Payload, Path, Topic),
  {noreply, State};
handle_cast(_Request, State = #state{}) ->
  {noreply, State}.

%% @private
%% @doc Handling all non call/cast messages
-spec(handle_info(Info :: timeout() | term(), State :: #state{}) ->
  {noreply, NewState :: #state{}} |
  {noreply, NewState :: #state{}, timeout() | hibernate} |
  {stop, Reason :: term(), NewState :: #state{}}).
handle_info(_Info, State = #state{}) ->
  {noreply, State}.

%% @private
%% @doc This function is called by a gen_server when it is about to
%% terminate. It should be the opposite of Module:init/1 and do any
%% necessary cleaning up. When it returns, the gen_server terminates
%% with Reason. The return value is ignored.
-spec(terminate(Reason :: (normal | shutdown | {shutdown, term()} | term()),
    State :: #state{}) -> term()).
terminate(_Reason, _State = #state{}) ->
  ok.

%% @private
%% @doc Convert process state when code is changed
-spec(code_change(OldVsn :: term() | {down, term()}, State :: #state{},
    Extra :: term()) ->
  {ok, NewState :: #state{}} | {error, Reason :: term()}).
code_change(_OldVsn, State = #state{}, _Extra) ->
  {ok, State}.

%%%===================================================================
%%% Internal functions
%%%===================================================================

send_notification(Token, Payload, Path, Topic) ->

  NewToken = mod_pushoff_utils:force_string(base64:decode(Token)),
  NewPath = mod_pushoff_utils:force_string(Path),
  NewTopic = mod_pushoff_utils:force_string(Topic),
  PushType = mod_pushoff_message:push_type(Payload),
  execute_curl(PushType, NewPath, NewTopic, NewToken, Payload).

execute_curl(voip, Path, Topic, Token, Payload) ->

  ?DEBUG("Payload = ~p~n ",[Payload]),

  ApnPushType = proplists:get_value(apns_push_type, Payload),
  Type = proplists:get_value(type, Payload),
  Status = proplists:get_value(status, Payload),
  RoomId = proplists:get_value(roomid, Payload),
  Sender = proplists:get_value(sender, Payload),
  Time = proplists:get_value(time, Payload),

  VoipTopic = Topic,
  Cmd = Path
    ++ " '" ++ VoipTopic
    ++ "' '" ++ Token
    ++ "' '" ++ ApnPushType
    ++ "' '" ++ binary_to_list(Type)
    ++ "' '" ++ binary_to_list(Status)
    ++ "' '" ++ binary_to_list(RoomId)
    ++ "' '" ++ binary_to_list(Sender)
    ++ "' '" ++ binary_to_list(Time)
    ++ "'",

  ?DEBUG("cmd = ~p~n ",[Cmd]),
  Result = os:cmd(Cmd),
  ?DEBUG("Result = ~p~n ",[Result]),
  ok;
execute_curl(body, Path, Topic, Token, Payload) ->

  ApnPushType = mod_pushoff_message:apns_push_type(Payload),
  Title = mod_pushoff_message:title(Payload),
  Body = mod_pushoff_message:body(Payload),
  MessageId = mod_pushoff_message:message_id(Payload),
  From = mod_pushoff_message:from(Payload),

  Cmd = Path
    ++ " '" ++ Topic
    ++ "' '" ++ Token
    ++ "' '" ++ ApnPushType
    ++ "' '" ++ Title
    ++ "' '" ++ Body
    ++ "' '" ++ binary_to_list(MessageId)
    ++ "' '" ++ From  
    ++ "'",
  ?DEBUG("cmd = ~p~n ",[Cmd]),
  Result = os:cmd(Cmd),
  ?DEBUG("Result = ~p~n ",[Result]),
  ok;
execute_curl(message, Path, Topic, Token, Payload) ->
  ApnPushType = mod_pushoff_message:apns_push_type(Payload),
  Title = mod_pushoff_message:title(Payload),
  MessageId = mod_pushoff_message:message_id(Payload),
  From = mod_pushoff_message:from(Payload),

  Cmd = Path
    ++ " '" ++ Topic
    ++ "' '" ++ Token
    ++ "' '" ++ ApnPushType
    ++ "' '" ++ Title
    ++ "' '" ++ binary_to_list(<<>>)
    ++ "' '" ++ binary_to_list(MessageId) 
    ++ "' '" ++ From
    ++ "'",
  ?INFO_MSG("cmd = ~p~n ",[Cmd]),
  Result = os:cmd(Cmd),
  ?DEBUG("Result = ~p~n ",[Result]),
  ok.
