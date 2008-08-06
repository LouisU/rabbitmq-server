%%   The contents of this file are subject to the Mozilla Public License
%%   Version 1.1 (the "License"); you may not use this file except in
%%   compliance with the License. You may obtain a copy of the License at
%%   http://www.mozilla.org/MPL/
%%
%%   Software distributed under the License is distributed on an "AS IS"
%%   basis, WITHOUT WARRANTY OF ANY KIND, either express or implied. See the
%%   License for the specific language governing rights and limitations
%%   under the License.
%%
%%   The Original Code is RabbitMQ.
%%
%%   The Initial Developers of the Original Code are LShift Ltd.,
%%   Cohesive Financial Technologies LLC., and Rabbit Technologies Ltd.
%%
%%   Portions created by LShift Ltd., Cohesive Financial Technologies
%%   LLC., and Rabbit Technologies Ltd. are Copyright (C) 2007-2008
%%   LShift Ltd., Cohesive Financial Technologies LLC., and Rabbit
%%   Technologies Ltd.;
%%
%%   All Rights Reserved.
%%
%%   Contributor(s): ______________________________________.
%%

-module(rabbit_exchange).
-include_lib("stdlib/include/qlc.hrl").
-include("rabbit.hrl").
-include("rabbit_framing.hrl").

-export([recover/0, declare/5, lookup/1, lookup_or_die/1,
         list_vhost_exchanges/1, list_exchange_bindings/1,
         simple_publish/6, simple_publish/3,
         route/2]).
-export([add_binding/1, delete_binding/1]).
-export([delete/2]).
-export([check_type/1, assert_type/2, topic_matches/2]).

-import(mnesia).
-import(sets).
-import(lists).
-import(qlc).
-import(regexp).

%%----------------------------------------------------------------------------

-ifdef(use_specs).

-type(publish_res() :: {'ok', [pid()]} |
      not_found() | {'error', 'unroutable' | 'not_delivered'}).

-spec(recover/0 :: () -> 'ok').
-spec(declare/5 :: (name(), exchange_type(), bool(), bool(),
                    amqp_table()) -> exchange()).
-spec(check_type/1 :: (binary()) -> atom()).
-spec(assert_type/2 :: (exchange(), atom()) -> 'ok').
-spec(lookup/1 :: (exchange_name()) -> {'ok', exchange()} | not_found()).
-spec(lookup_or_die/1 :: (exchange_name()) -> exchange()).
-spec(list_vhost_exchanges/1 :: (vhost()) -> [exchange()]).
-spec(list_exchange_bindings/1 :: (exchange_name()) ->
             [{queue_name(), routing_key(), amqp_table()}]).
-spec(simple_publish/6 ::
      (bool(), bool(), exchange_name(), routing_key(), binary(), binary()) ->
             publish_res()).
-spec(simple_publish/3 :: (bool(), bool(), message()) -> publish_res()).
-spec(route/2 :: (exchange(), routing_key()) -> [pid()]).
% -spec(add_binding/2 :: (binding_spec(), amqqueue()) ->
%              'ok' | not_found() |
%                  {'error', 'durability_settings_incompatible'}).
% -spec(delete_binding/2 :: (binding_spec(), amqqueue()) ->
%              'ok' | not_found()).
-spec(topic_matches/2 :: (binary(), binary()) -> bool()).
-spec(delete/2 :: (exchange_name(), bool()) ->
             'ok' | not_found() | {'error', 'in_use'}).

-endif.

%%----------------------------------------------------------------------------

recover() ->
    ok = recover_default_exchange(),
    ok = recover_durable_exchanges(),
    ok.

recover_default_exchange() ->
    rabbit_misc:execute_mnesia_transaction(
      fun () -> mnesia:write(#exchange{name = <<"">>}) end).

recover_durable_exchanges() ->
    rabbit_misc:execute_mnesia_transaction(
      fun () ->
              mnesia:foldl(fun (Exchange, Acc) ->
                                   ok = mnesia:write(Exchange),
                                   Acc
                           end, ok, durable_exchanges)
      end).

declare(Resource = #resource{}, Type, Durable, AutoDelete, Args) ->
    Exchange = #exchange{name = Resource,
                         type = Type,
                         durable = Durable,
                         auto_delete = AutoDelete,
                         arguments = Args},
    rabbit_misc:execute_mnesia_transaction(
      fun () ->
              case mnesia:wread({exchange, Resource}) of
                  [] -> ok = mnesia:write(Exchange),
                        if Durable ->
                                ok = mnesia:write(
                                       durable_exchanges, Exchange, write);
                           true -> ok
                        end,
                        Exchange;
                  [ExistingX] -> ExistingX
              end
      end).

check_type(<<"fanout">>) ->
    fanout;
check_type(<<"direct">>) ->
    direct;
check_type(<<"topic">>) ->
    topic;
check_type(T) ->
    rabbit_misc:protocol_error(
      command_invalid, "invalid exchange type '~s'", [T]).

assert_type(#exchange{ type = ActualType }, RequiredType)
  when ActualType == RequiredType ->
    ok;
assert_type(#exchange{ name = Name, type = ActualType }, RequiredType) ->
    rabbit_misc:protocol_error(
      not_allowed, "cannot redeclare ~s of type '~s' with type '~s'",
      [rabbit_misc:rs(Name), ActualType, RequiredType]).

lookup(Name) ->
    rabbit_misc:dirty_read({exchange, Name}).

lookup_or_die(Resource = #resource{name = Name}) ->
    case lookup(Resource) of
        {ok, X} -> X;
        {error, not_found} ->
            rabbit_misc:protocol_error(
              not_found, "no ~s", [rabbit_misc:rs(#resource{virtual_host = <<"/">>, kind = exchange, name = Name})])
    end.

list_vhost_exchanges(VHostPath) ->
    mnesia:dirty_match_object(
      #exchange{name = rabbit_misc:r(VHostPath, exchange), _ = '_'}).

list_exchange_bindings(Name) ->
    exit(list_exchange_bindings).
    % [{QueueName, RoutingKey, Arguments} ||
    %     #binding{handlers = Handlers} <- bindings_for_exchange(Name),
    %     #handler{binding_spec = #binding_spec{routing_key = RoutingKey,
    %                           arguments = Arguments},
    %          queue = QueueName} <- Handlers].

% Maybe this named wrongly - it returns a route
bindings_for_exchange(Name) ->
    qlc:e(qlc:q([R || R = #route{binding = #binding{exchange_name = N}} <- mnesia:table(route),
                      N == Name])).

empty_handlers() ->
    [].

%% Usable by Erlang code that wants to publish messages.
simple_publish(Mandatory, Immediate, ExchangeName, RoutingKeyBin, ContentTypeBin, BodyBin) ->
    {ClassId, _MethodId} = rabbit_framing:method_id('basic.publish'),
    Content = #content{class_id = ClassId,
                       properties = #'P_basic'{content_type = ContentTypeBin},
                       properties_bin = none,
                       payload_fragments_rev = [BodyBin]},
    Message = #basic_message{exchange_name = ExchangeName,
                             routing_key = RoutingKeyBin,
                             content = Content,
                             persistent_key = none},
    simple_publish(Mandatory, Immediate, Message).

%% Usable by Erlang code that wants to publish messages.
simple_publish(Mandatory, Immediate,
               Message = #basic_message{exchange_name = ExchangeName,
                                        routing_key = RoutingKey}) ->
    case lookup(ExchangeName) of
        {ok, Exchange} ->
            QPids = route(Exchange, RoutingKey),
            rabbit_router:deliver(QPids, Mandatory, Immediate,
                                  none, Message);
        {error, Error} -> {error, Error}
    end.

%% return the list of qpids to which a message with a given routing
%% key, sent to a particular exchange, should be delivered.
%%
%% The function ensures that a qpid appears in the return list exactly
%% as many times as a message should be delivered to it. With the
%% current exchange types that is at most once.
route(#exchange{name = Name, type = topic}, RoutingKey) ->
    route_internal(Name, RoutingKey, fun topic_matches/2);

route(#exchange{name = Name, type = Type}, RoutingKey) ->
    route_internal(Name, RoutingKey, fun(X,Y) -> X == Y end).

% This returns a list of QPids to route to.
% Maybe this should be handled by a cursor instead.
route_internal(Exchange, RoutingKey, MatchFun) ->
    Query = qlc:q([QPid || #route{binding = #binding{exchange_name = ExchangeName,
                                                     queue_name = QueueName,
                                                     key = BindingKey}} <- mnesia:table(route),
                           #amqqueue{name = Queue, pid = QPid} <- mnesia:table(amqqueue),
                           ExchangeName == Exchange,
                           QueueName == Queue,
                           MatchFun(BindingKey, RoutingKey)]),
    mnesia:activity(async_dirty, fun() -> qlc:e(Query) end).

delivery_key_for_type(fanout, Name, _RoutingKey) ->
    {Name, fanout};
delivery_key_for_type(_Type, Name, RoutingKey) ->
    {Name, RoutingKey}.

% Don't really like this double lookup
% It seems very clunky
% Can this get refactored to to avoid the duplication of the lookup/1 function?
call_with_exchange_and_queue(#binding{exchange_name = Exchange,
                                      queue_name = Queue}, Fun) ->
    case mnesia:wread({exchange, Exchange}) of
        [] -> {error, exchange_not_found};
        [X] ->
            case mnesia:wread({amqqueue, Queue}) of
                [] -> {error, queue_not_found};
                [Q] ->
                    Fun(X,Q)
            end
    end.


make_handler(BindingSpec, #amqqueue{name = QueueName, pid = QPid}) ->
    exit(make_handler).
    %#handler{binding_spec = BindingSpec, queue = QueueName, qpid = QPid}.

add_binding(Binding) ->
    call_with_exchange_and_queue(
        Binding,
        fun (X,Q) -> if Q#amqqueue.durable and not(X#exchange.durable) ->
                            {error, durability_settings_incompatible};
                         true ->
                             internal_add_binding(Binding)
                     end
        end).

delete_binding(Binding) ->
    call_with_exchange_and_queue(
         Binding,
         fun (X,Q) -> ok = internal_delete_binding(Binding)
         end).
    % call_with_exchange(
    %   ExchangeName,
    %   fun (X) -> ok = internal_delete_binding(
    %                     X, RoutingKey, make_handler(BindingSpec, Q)),
    %              maybe_auto_delete(X)
    %   end).

%% Must run within a transaction.
maybe_auto_delete(#exchange{auto_delete = false}) ->
    ok;
maybe_auto_delete(#exchange{name = ExchangeName, auto_delete = true}) ->
    case internal_delete(ExchangeName, true) of
        {error, in_use} -> ok;
        ok -> ok
    end.

handlers_isempty([])    -> true;
handlers_isempty([_|_]) -> false.

extend_handlers(Handlers, Handler) -> [Handler | Handlers].

delete_handler(Handlers, Handler) -> lists:delete(Handler, Handlers).

handler_qpids(Handlers) ->
    exit(handler_qpids).
    %sets:from_list([QPid || #handler{qpid = QPid} <- Handlers]).

reverse_binding(#binding{exchange_name = Exchange, key = Key, queue_name = Queue}) ->
    #reverse_binding{exchange_name = Exchange, key = Key, queue_name = Queue}.

%% Must run within a transaction.
internal_add_binding(Binding) ->
    Forwards = #route{ binding = Binding },
    Reverse = #reverse_route{ reverse_binding = reverse_binding(Binding) },
    ok = mnesia:write(Forwards),
    ok = mnesia:write(Reverse).

%% Must run within a transaction.
internal_delete_binding(Binding) ->
    % This is copy and paste from the function above
    Forwards = #route{ binding = Binding },
    Reverse = #reverse_route{ reverse_binding = reverse_binding(Binding) },
    ok = mnesia:delete_object(Forwards),
    ok = mnesia:delete_object(Reverse).



%% Must run within a transaction.
add_handler_to_binding(BindingKey, Handler) ->
    exit(add_handler_to_binding).
    % ok = case mnesia:wread({binding, BindingKey}) of
    %              [] ->
    %                  ok = mnesia:write(
    %                         #binding{key = BindingKey,
    %                                  handlers = extend_handlers(
    %                                               empty_handlers(), Handler)});
    %              [B = #binding{handlers = H}] ->
    %                  ok = mnesia:write(
    %                         B#binding{handlers = extend_handlers(H, Handler)})
    %          end.

%% Must run within a transaction.
remove_handler_from_binding(BindingKey, Handler) ->
    exit(remove_handler_from_binding).
    % case mnesia:wread({binding, BindingKey}) of
    %         [] -> empty;
    %         [B = #binding{handlers = H}] ->
    %             H1 = delete_handler(H, Handler),
    %             case handlers_isempty(H1) of
    %                 true ->
    %                     ok = mnesia:delete({binding, BindingKey}),
    %                     empty;
    %                 _ ->
    %                     ok,% = mnesia:write(B#binding{handlers = H1}),
    %                     not_empty
    %             end
    %     end.

split_topic_key(Key) ->
    {ok, KeySplit} = regexp:split(binary_to_list(Key), "\\."),
    KeySplit.

topic_matches(PatternKey, RoutingKey) ->
    P = split_topic_key(PatternKey),
    R = split_topic_key(RoutingKey),
    topic_matches1(P, R).

topic_matches1(["#"], _R) ->
    true;
topic_matches1(["#" | PTail], R) ->
    last_topic_match(PTail, [], lists:reverse(R));
topic_matches1([], []) ->
    true;
topic_matches1(["*" | PatRest], [_ | ValRest]) ->
    topic_matches1(PatRest, ValRest);
topic_matches1([PatElement | PatRest], [ValElement | ValRest]) when PatElement == ValElement ->
    topic_matches1(PatRest, ValRest);
topic_matches1(_, _) ->
    false.

last_topic_match(P, R, []) ->
    topic_matches1(P, R);
last_topic_match(P, R, [BacktrackNext | BacktrackList]) ->
    topic_matches1(P, R) or last_topic_match(P, [BacktrackNext | R], BacktrackList).

delete(ExchangeName, IfUnused) ->
    rabbit_misc:execute_mnesia_transaction(
      fun () -> internal_delete(ExchangeName, IfUnused) end).

internal_delete(ExchangeName, _IfUnused = true) ->
    exit(internal_delete);
    % Bindings = bindings_for_exchange(ExchangeName),
    %     case Bindings of
    %         [] -> do_internal_delete(ExchangeName, Bindings);
    %         _ ->
    %             case lists:all(fun (#binding{handlers = H}) -> handlers_isempty(H) end,
    %                            Bindings) of
    %                 true ->
    %                     %% There are no handlers anywhere in any of the
    %                     %% bindings for this exchange.
    %                     do_internal_delete(ExchangeName, Bindings);
    %                 false ->
    %                     %% There was at least one real handler
    %                     %% present. It's still in use.
    %                     {error, in_use}
    %             end
    %     end;
internal_delete(ExchangeName, false) ->
    do_internal_delete(ExchangeName, bindings_for_exchange(ExchangeName)).

% Don't know if iterating over a list in process memory is cool
% Maybe we should iterate over the DB cursor?
do_internal_delete(ExchangeName, Bindings) ->
    case mnesia:wread({exchange, ExchangeName}) of
            [] -> {error, not_found};
            _ ->
                lists:foreach(fun (B) -> ok = mnesia:delete_object(B) end, Bindings),
                ok = mnesia:delete({durable_exchanges, ExchangeName}),
                ok = mnesia:delete({exchange, ExchangeName})
    end.
