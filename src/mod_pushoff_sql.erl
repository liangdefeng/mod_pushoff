%%%
-module(mod_pushoff_sql).

-author('defeng.liang.cn@gmail.com').

-export([
  register_client/3,
  unregister_client/1,
  unregister_client/2,
  list_registrations/1,
  list_registrations_all/1]).

-include("logger.hrl").
-include("mod_pushoff.hrl").
-include("ejabberd_sql_pt.hrl").

-include("xmpp_codec.hrl").

-compile(export_all).

-spec(register_client(key(), backend_id(), binary()) ->
             {error, stanza_error()} |
             {registered, ok}).
register_client(Key, Backend, Token) ->
  ?DEBUG("register_client#start", []),
  ?DEBUG("key:~p, Backend:~p, Token:~p~n", [Key, Backend, Token]),

  {BackendServer, {BackendId, BackendRef}} = Backend,
  BackendIdBin = atom_to_binary(BackendId, utf8),
  {User, Server, PushType} = Key,
  BareJid = <<User/binary, "@", Server/binary>>,
  case ejabberd_sql:sql_query(Server,
    ?SQL("select @(bare_jid)s,"
            "@(push_type)d "
            "from pushoff_tbl "
            "where bare_jid=%(BareJid)s and push_type=%(PushType)d"))
  of
    {selected, []} ->
      Now = erlang:system_time(millisecond),
      case ejabberd_sql:sql_query(Server, ?SQL_INSERT(
        "pushoff_tbl",
        ["bare_jid=%(BareJid)s",
          "push_type=%(PushType)d",
          "token=%(Token)s",
          "backend_server=%(BackendServer)s",
          "backend_id=%(BackendIdBin)s",
          "backend_ref=%(BackendRef)s",
          "`timestamp`=%(Now)d"
        ])
      ) of
        {updated, _} ->
          {registered, ok};
        Err ->
          ?ERROR_MSG("register_client error:~p~n", [Err]),
          {error, xmpp:err_internal_server_error()}
      end;
    {selected, _Result} ->
      Now = erlang:system_time(millisecond),
      F = fun() -> update_token(BareJid, PushType, Token, BackendServer, BackendIdBin, BackendRef, Now) end,
      case ejabberd_sql:sql_transaction(Server, F) of
        {atomic, _} ->
          {registered, ok};
        Err ->
          ?ERROR_MSG("register_client error:~p~n", [Err]),
          {error, xmpp:err_internal_server_error()}
      end;
    Error ->
      ?ERROR_MSG("register_client error:~p~n", [Error]),
      {error, xmpp:err_internal_server_error()}
  end.

% Update pushoff_tbl, especially the token.
update_token(BareJid, PushType, Token, BackendServer, BackendIdBin, BackendRef, Now) ->
  ?SQL_UPSERT_T(
    "pushoff_tbl",
    ["!bare_jid=%(BareJid)s",
      "!push_type=%(PushType)d",
      "token=%(Token)s",
      "backend_server=%(BackendServer)s",
      "backend_id=%(BackendIdBin)s",
      "backend_ref=%(BackendRef)s",
      "timestamp=%(Now)d"
    ]).

-spec(unregister_client({key(), erlang:timestamp()}) ->
            {error, stanza_error()} |
            {unregistered, [pushoff_registration()]}).
unregister_client({Key, Timestamp}) ->
  {User, Server, PushType} = Key,
  BareJid = <<User/binary, "@", Server/binary>>,
  case ejabberd_sql:sql_query(Server,
    ?SQL("select @(bare_jid)s,"
          "@(push_type)d,"
          "@(token)s,"
          "@(backend_server)s,"
          "@(backend_id)s,"
          "@(backend_ref)s,"
          "@(`timestamp`)d "
          "from pushoff_tbl "
          "where bare_jid=%(BareJid)s and push_type=%(PushType)d"))
  of
    {selected, []} ->
      {unregistered, []};
    {select, Result} ->
      case ejabberd_sql:sql_query(Server,
        ?SQL("delete from pushoff_tbl where bare_jid=%(BareJid)s and timestamp=%(Timestamp)d"))
      of
        {updated, _Num} ->
          RetList = [#pushoff_registration{
            key = Key,
            token = Token,
            backend_id = {BackendServer, {binary_to_atom(BackendId, utf8), BackendRef}},
            backend_ref = BackendRef,
            timestamp = Time}
            || {_Barejid, _PushType, Token, BackendServer, BackendId, BackendRef, Time} <- Result],
          {unregistered, RetList};
        Error2 ->
          ?ERROR_MSG("unregister_client error:~p~n", [Error2]),
          {error, xmpp:err_internal_server_error()}
      end;
    Error ->
      ?ERROR_MSG("unregister_client error:~p~n", [Error]),
      {error, xmpp:err_internal_server_error()}
  end.

-spec(unregister_client(User :: binary(), Server :: binary()) ->
             {error, stanza_error()} |
             {unregistered, [pushoff_registration()]}).
unregister_client(User, Server) ->
  BareJid = <<User/binary, "@", Server/binary>>,
  case ejabberd_sql:sql_query(Server,
    ?SQL("select @(bare_jid)s,"
          "@(push_type)d,"
          "@(token)s,"
          "@(backend_server)s,"
          "@(backend_id)s,"
          "@(backend_ref)s,"
          "@(`timestamp`)d "
          "from pushoff_tbl "
          "where bare_jid=%(BareJid)s"))
  of
    {selected, []} ->
      {unregistered, []};
    {selected, Result} ->
      case ejabberd_sql:sql_query(Server,
        ?SQL("delete from pushoff_tbl where bare_jid=%(BareJid)s"))
      of
        {updated, _Num} ->
          RetList = [#pushoff_registration{
            key = {User, Server, PushType},
            token = Token,
            backend_id = {BackendServer, {binary_to_atom(BackendId, utf8), BackendRef}},
            backend_ref = BackendRef,
            timestamp = Time}
            || {_Barejid, PushType, Token, BackendServer, BackendId, BackendRef, Time} <- Result],
          {unregistered, RetList};
        Error2 ->
          ?ERROR_MSG("unregister_client error:~p~n", [Error2]),
          {error, xmpp:err_internal_server_error()}
      end;
    Error ->
      ?ERROR_MSG("unregister_client error:~p~n", [Error]),
      {error, xmpp:err_internal_server_error()}
  end.

-spec(list_registrations(key()) -> {error, stanza_error()} |
                                   {registrations, [pushoff_registration()]}).

list_registrations(Key) ->
  {User, Server, PushType} = Key,
  BareJid = <<User/binary, "@", Server/binary>>,
  case ejabberd_sql:sql_query(Server,
    ?SQL("select @(bare_jid)s,"
          "@(push_type)d,"
          "@(token)s,"
          "@(backend_server)s,"
          "@(backend_id)s,"
          "@(backend_ref)s,"
          "@(`timestamp`)d "
          "from pushoff_tbl "
          "where bare_jid=%(BareJid)s and push_type=%(PushType)d"))
  of
    {selected, Result} ->
      RegList = [#pushoff_registration{
        key = Key,
        token = Token,
        backend_id = {BackendServer, {binary_to_atom(BackendId, utf8), BackendRef}},
        backend_ref = BackendRef,
        timestamp = Time}
        || {_Barejid, _PushType, Token, BackendServer, BackendId, BackendRef, Time} <- Result],
      {registrations, RegList};
    Error ->
      ?ERROR_MSG("list_registrations error:~p~n", [Error]),
      {error, xmpp:err_internal_server_error()}
  end.

list_registrations_all({User, Server}) ->
  BareJid = <<User/binary, "@", Server/binary>>,
  case ejabberd_sql:sql_query(Server,
    ?SQL("select @(bare_jid)s,"
            "@(push_type)d,"
            "@(token)s,"
            "@(backend_server)s,"
            "@(backend_id)s,"
            "@(backend_ref)s,"
            "@(`timestamp`)d "
            "from pushoff_tbl "
            "where bare_jid=%(BareJid)s"))
  of
    {selected, Result} ->
      RegList = [#pushoff_registration{
        key = {User, Server, PushType},
        token = Token,
        backend_id = {BackendServer, {binary_to_atom(BackendId, utf8), BackendRef}},
        backend_ref = BackendRef,
        timestamp = Time}
        || {_Barejid, PushType, Token, BackendServer, BackendId, BackendRef, Time} <- Result],
      {registrations, RegList};
    Error ->
      ?ERROR_MSG("list_registrations_all error:~p~n", [Error]),
      {error, xmpp:err_internal_server_error()}
  end.