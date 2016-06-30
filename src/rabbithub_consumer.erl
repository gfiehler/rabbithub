-module(rabbithub_consumer).

-behaviour(gen_server).

-export([init/1, handle_call/3, handle_cast/2, handle_info/2, terminate/2, code_change/3, erase_subscription_err/1]).

-include("rabbithub.hrl").
-include_lib("rabbit_common/include/rabbit.hrl").
-include_lib("rabbit_common/include/rabbit_framing.hrl").

-record(state, {subscription, q_monitor_ref, consumer_tag}).

init([Lease = #rabbithub_lease{subscription = Subscription}]) ->

    process_flag(trap_exit, true),
    case rabbithub_subscription:register_subscription_pid(Lease, self(), ?MODULE) of
        ok ->            
            really_init(Subscription);
        expired ->            
            {stop, normal};
        duplicate ->
            {stop, normal}
    end.

really_init(Subscription = #rabbithub_subscription{resource = Resource}) ->   
    %% create consumer tag prefix with local node server name
    Node = node(),
    NodeTemp = io_lib:format("~p",[Node]),
    NodeString = lists:flatten(NodeTemp),
    %% strip single quotes of ends in case the node name has special characters or capitol letters
    NodeStringStripped = string:strip(NodeString, both, $'),
    Server = string:sub_word(NodeStringStripped, 2, $@),
    Prefix = "amq.http.consumer." ++ Server,
    
    case rabbit_amqqueue:lookup(Resource) of
        {ok, Q = #amqqueue{pid = QPid}} ->
            
            ConsumerTag = rabbit_guid:binary(rabbit_guid:gen(), Prefix),

            MonRef = erlang:monitor(process, QPid),
            %% Note that prefetch count is set to 1. This will likely have some impact
            %% on performance; however this is an internal consumer and HTTP POST
            %% operations will invariably be the rate-limiting step. Setting prefetch
            %% count to 1 allows better control over HTTP error handling.
            rabbit_amqqueue:basic_consume(Q, false, self(), undefined, false, 1,
                                          ConsumerTag, false, [], undefined),
            rabbit_log:info("RabbitHub started consumer with tag:  ~p on local node ~p~n", [ConsumerTag, Node]),                                          
            {ok, #state{subscription = Subscription,
                        q_monitor_ref = MonRef,
                        consumer_tag = ConsumerTag}};
        {error, not_found} ->
            ok = rabbithub:error_and_unsub(Subscription,
                                           {rabbithub_consumer, queue_not_found, Subscription}),
            {stop, not_found}
    end.

handle_call(Request, _From, State) ->
    {stop, {unhandled_call, Request}, State}.

handle_cast({deliver, _ConsumerTag, AckRequired,
             {_QNameResource, QPid, MsgId, Redelivered, BasicMessage}},
            State = #state{subscription = Subscription}) ->
    case rabbithub:deliver_via_post(Subscription,
                                    BasicMessage,
                                    [{"X-AMQP-Redelivered", atom_to_list(Redelivered)}]) of
        {ok, _} ->            
            ok = rabbit_amqqueue:notify_sent(QPid, self()),
            case AckRequired of
                true ->                    
                    ok = rabbit_amqqueue:ack(QPid, [MsgId], self());
                false ->                    
                    ok
            end;
        {error, Reason} ->
            case is_integer(Reason) of 
                true ->                    
                    %% If requeue_on_http_post_error is set to false then messages associated with
                    %% failed HTTP POSTs will be dropped or published to a dead letter exchange (if
                    %% one is associated with the subscription queue in question). Note 
                    %% that this ties in with setting the prefetch count to 1 (see above), which
                    %% ensures that at most 2 messages will be rejected per error before the
                    %% subscription gets deleted and the consumer processes is terminated. This
                    %% setting is primarily intended for debugging purposes. For example, bad data
                    %% might cause the receiving web application to break. By using this setting
                    %% in conjunction with a dead letter exchange (and queue) it is possible to 
                    %% capture the offending messages, rather than have them end up back on the 
                    %% subscription queue and getting stuck in some sort of error loop.
                    case application:get_env(rabbithub, requeue_on_http_post_error) of
                       {ok, false} ->
                           ok = rabbit_amqqueue:notify_sent(QPid, self()),                           
                           case AckRequired of
                               true ->                                   
                                   ok = rabbit_amqqueue:reject(QPid, false, [MsgId], self());
                               false ->
                                   ok
                           end;
                       _ ->                           
                           ok
                       end;
                false ->                    
                    ok
            end,
            %% Added New configuration to control when a consumer is unscubscribed due to errors.
            %%  If unsubscribe_on_http_post_error_limit and unsubscribe_on_http_post_error_timeout_microseconds
            %%  are set.  Use these to govern when to unsubscribe.  Only unsubscribe if more than 
            %%  unsubscribe_on_http_post_error_limit errors have occurred within 
            %%  unsubscribe_on_http_post_error_timeout_microseconds microseconds.
            %%  This allows for some intermittent errors to occur without unsubscribing but can control
            %%  so that it does not spin in an endless loop.  This is tracked per subscriber in the
            %%  rabbithub_subscription_err ram only table.  Re-subscribing consumer resets counts.
            case application:get_env(rabbithub, unsubscribe_on_http_post_error_limit) of
                {ok, ErrorLimit} when is_integer(ErrorLimit)->
                    case application:get_env(rabbithub, unsubscribe_on_http_post_error_timeout_microseconds) of
                        {ok, ErrorTimeout} when is_integer(ErrorTimeout)->                            
                            case register_subscription_err(Subscription, ErrorLimit, ErrorTimeout) of
                                unsubscribe ->
                                    ok = rabbithub:error_and_unsub(Subscription,
                                          {rabbithub_consumer, http_post_failure, Reason});

                                do_not_unsubscribe ->
                                    ok
                            end; 
			            _ ->
			                %% unsubscribe_on_http_post_error_timeout_minutes not configured but is required
			                rabbit_log:warning("Rabbithub Environment Variable unsubscribe_on_http_post_error_limit set without unsubscribe_on_http_post_error_timeout_microseconds.~nThese must be set as a pair, ignoring configuraton.~n"),                         
			                ok = rabbithub:error_and_unsub(Subscription,
                                           {rabbithub_consumer, http_post_failure, Reason})
		            end;
                _ -> 
                    %% unsubscribe_on_http_post_error_limit not configured, only requeue_on_http_post_error set to false, unsubscribe on each error                    
                    ok = rabbithub:error_and_unsub(Subscription,
                                           {rabbithub_consumer, http_post_failure, Reason})
            end		
    end,    
    {noreply, State};
    
handle_cast(shutdown, State) ->    
    {stop, normal, State};

handle_cast(Request, State) ->    
    {stop, {unhandled_cast, Request}, State}.

handle_info(Request, State) ->
    {stop, {unhandled_info, Request}, State}.

terminate(_Reason, _State = #state{subscription = Subscription}) ->
    ok = rabbithub_subscription:erase_subscription_pid(Subscription),
    ok.

code_change(_OldVsn, State, _Extra) ->
    {ok, State}.

%% GF: Function to check if the error count and time limits have been reached
%% when unsubscribe_on_http_post_error_limit and unsubscribe_on_http_post_error_timeout_microseconds are set
%% only unsubscribe if the subscriber has returned an error to a post more than
%% unsubscribe_on_http_post_error_limit times within unsubscribe_on_http_post_error_timeout_min minutes
%%-record(rabbithub_subscription_err, {subscription, error_count, first_error_time_microsec, last_error_time_microsec}). 
register_subscription_err(Subscription, ErrorLimit, ErrorTimeout) ->
    NowMicro = rabbithub_subscription:system_time(),    
    
    NewErrRecord = #rabbithub_subscription_err{subscription = Subscription,
                                                       error_count = 1,
                                                       first_error_time_microsec = NowMicro,
                                                       last_error_time_microsec  = NowMicro},

    {atomic, Result} =
        mnesia:transaction(
          fun () ->
                  case mnesia:read(rabbithub_subscription_err, Subscription) of
                      [] ->
                          %% empty record for subscription, create new record
                          ok = mnesia:write(NewErrRecord), 
                          rabbit_log:warning("Rabbithub HTTP POST error occurred.  Create New Error Count ~n~p~n", [NewErrRecord]),
                          %% if error limit is 0, unsubscribe otherwise do not
                          case ErrorLimit of
                            0 ->                                
                                unsubscribe;
                            EL ->                                
                                do_not_unsubscribe
                          end;
                      [ExistingRecord =
                         #rabbithub_subscription_err{error_count = ErrorCount,
                                                        first_error_time_microsec = FirstErrorTimeMicro,
                                                        last_error_time_microsec  = _LastErrorTimeMicro}] ->             
                          %% existing record
                          %% check if error set time is greater than timeout                          
                          case ((NowMicro - FirstErrorTimeMicro) > (ErrorTimeout)) of                                 
                              true ->
                                  %% error interval has timed out, update with new fist error time
                                  %% and an error count of 1 (NewErrRecord)                                      
                                  ok = mnesia:write(NewErrRecord), 
                                  %% if error limit is 0, unsubscribe otherwise do not
                                  case ErrorLimit of
                                    0 ->                                        
                                        unsubscribe;
                                    EL ->                                         
                                        do_not_unsubscribe
                                  end;                                                                   
                              false ->
                                  %% new error within time interval
                                  NewErrorCount = ErrorCount + 1,
                                  %% check error limit
                                  case NewErrorCount > ErrorLimit of
                                      true ->
                                          %%update error timeout and return unsubscribe                             
                                          UpdatedExistingRecord = ExistingRecord#rabbithub_subscription_err{error_count = NewErrorCount,
                                                                                                                last_error_time_microsec = NowMicro},
                                          ok = mnesia:write(UpdatedExistingRecord),                                          
                                          rabbit_log:warning("Rabbithub HTTP POST error occurred.  Update Error Count and unsubscribe consumer ~n~p~n", [UpdatedExistingRecord]),
                                          unsubscribe;
                                      false ->
                                          %% update error_count and return do_not_unsubscribe                                          
                                          UpdatedExistingRecord = ExistingRecord#rabbithub_subscription_err{error_count = NewErrorCount,
                                                                                                                last_error_time_microsec = NowMicro},                                          
                                          ok = mnesia:write(UpdatedExistingRecord),
                                          rabbit_log:warning("Rabbithub HTTP POST error occurred within configured limits.  Update Error Count ~n~p~n", [UpdatedExistingRecord]),
                                          do_not_unsubscribe
                                  end
                          end
                  end
          end),
    Result.

erase_subscription_err(Subscription) ->
    rabbit_log:info("Rabbithub Remove Error Record for Subscription: ~p~n",[Subscription]),
    {atomic, ok} =
        mnesia:transaction(fun () -> mnesia:delete({rabbithub_subscription_err, Subscription}) end),
    ok.
