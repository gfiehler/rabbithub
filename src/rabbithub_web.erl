-module(rabbithub_web).

-export([start/0, handle_req/1, listener/0]).

-include("rabbithub.hrl").
-include_lib("rabbit_common/include/rabbit.hrl").
-include_lib("rabbit_common/include/rabbit_framing.hrl").

-define(APPLICATION_XSLT, ("/" ++ rabbithub:canonical_basepath() ++ "/static/application.xsl.xml")).

-define(DEFAULT_SUBSCRIPTION_LEASE_SECONDS, (30 * 86400)).
-define(SUBSCRIPTION_LEASE_LIMIT, 1000 * 365 * 86400). %% Around a thousand years


start() ->
    Listener = listener(),
    rabbit_web_dispatch:register_context_handler(rabbithub:canonical_basepath(), Listener, "",
                                             fun (Req) -> ?MODULE:handle_req(Req) end,
                                             "RabbitHub"),
    ok.

listener() ->
    {ok, Listener} = application:get_env(rabbithub, listener),
    Listener.

split_path("", _) ->
    [<<>>];
split_path(Path, 1) ->
    [list_to_binary(Path)];
split_path(Path, N) ->
    case string:str(Path, "/") of
        0 ->
            [list_to_binary(Path)];
        Pos ->
            [list_to_binary(string:substr(Path, 1, Pos - 1))
             | split_path(string:substr(Path, Pos + 1), N - 1)]
    end.

%% handle_req(AliasPrefix, Req) ->
handle_req(Req) ->
    {FullPath, Query, _Fragment} = mochiweb_util:urlsplit_path(Req:get(raw_path)),
    %% plus one for the "/", plus one for the 1-based indexing for substr:
    Path = FullPath,
    ParsedQuery = mochiweb_util:parse_qs(Query),
    %% When we get to drop support for R12B-3, we can start using
    %% re:split(Path, "/", [{parts, 4}]) again.

    %% case split_path(Path, 4) of
    %% BRC
    case split_path(Path, 5) of
        [<<>>, <<"static">> | _] ->
            handle_static(Path, Req);
        [<<>>, <<>>] ->
            handle_static(Path, Req);
        [<<>>, Facet, ResourceType, Name] ->
            case check_resource_type(ResourceType) of
                {ok, ResourceTypeAtom} ->
                    handle_request(ResourceTypeAtom,
                                   binary_to_list(Facet),
                                   rabbithub:r(ResourceTypeAtom, binary_to_list(Name)),
                                   ParsedQuery,
                                   Req);
                {error, invalid_resource_type} ->
                    Req:not_found()
            end;
        %% GF: added case specific to retrieving list of subscriptions
        [<<>>, <<"subscriptions">>] ->
            handle_request(none,
                           binary_to_list(<<"subscriptions">>),
                           <<>>,
                           ParsedQuery,
                           Req);
        %% GF: added case for retrieving a list of http post errorrs
        [<<>>, <<"subscriptions">>, <<"errors">>] ->
            handle_request(errors,
                           binary_to_list(<<"subscriptions">>),
                           binary_to_list(<<"errors">>),
                           ParsedQuery,
                           Req);
        %% BRC
        [<<>>, VHost, Facet, ResourceType, Name] ->
            case check_resource_type(ResourceType) of
                {ok, ResourceTypeAtom} ->
                    handle_request(ResourceTypeAtom,
                                   binary_to_list(Facet),
                                   rabbithub:r(VHost, ResourceTypeAtom, binary_to_list(Name)),
                                   ParsedQuery,
                                   Req);
                {error, invalid_resource_type} ->
                    Req:not_found()
            end;
        _ ->
	    Req:not_found()
    end.

%% Internal API

check_resource_type(<<"x">>) -> {ok, exchange};
check_resource_type(<<"q">>) -> {ok, queue};
check_resource_type(<<"errors">>) -> {ok, errors};
%% GF: Not sure if needed here, but used new resource type to call perform_request
check_resource_type(<<"">>) -> {ok, none};
check_resource_type(_) -> {error, invalid_resource_type}.

check_facet('POST', "endpoint", "", _) -> {auth_required, [write]};
check_facet('PUT', "endpoint", "", queue) -> auth_not_required; %% special case: see implementation
check_facet('PUT', "endpoint", "", _) -> {auth_required, [configure]};
check_facet('DELETE', "endpoint", "", _) -> {auth_required, [configure]};
check_facet('GET', "endpoint", "", _) -> auth_not_required;
check_facet('GET', "endpoint", "generate_token", _) -> {auth_required, [write]};
check_facet('GET', "endpoint", "subscribe", _) -> auth_not_required;
check_facet('GET', "endpoint", "unsubscribe", _) -> auth_not_required;
check_facet('GET', "subscribe", "", _) -> auth_not_required;
check_facet('POST', "subscribe", "", _) -> auth_not_required; %% special case: see implementation
check_facet('POST', "subscribe", "subscribe", _) -> {auth_required, [read]};
check_facet('DELETE', "subscribe", _, _) -> {auth_required, [configure]};
%% GF: added new facet for getting a list of HTTP POST errors
check_facet('GET', "subscriptions", "", "errors") -> auth_required_rabbithub_admin;
%% GF: added new facet for getting a list of subscriptions
check_facet('GET', "subscriptions", "", _) -> auth_required_rabbithub_admin;
check_facet('POST', "subscriptions", "", _) -> auth_required_rabbithub_admin;
check_facet('POST', "subscribe", "unsubscribe", _) -> {auth_required, []};
check_facet(_Method, _Facet, _HubMode, _ResourceType) -> invalid_operation.

handle_static("/" ++ StaticFile, Req) ->
    case Req:get(method) of
        Method when Method =:= 'GET'; Method =:= 'HEAD' ->
            {file, Here} = code:is_loaded(?MODULE),
            ModuleRoot = filename:dirname(filename:dirname(Here)),
            DocRoot = filename:join(ModuleRoot, "priv/www"),
            Req:serve_file(StaticFile, DocRoot);
        'POST' ->
            case StaticFile of
                "" -> handle_hub_post(Req);
                _ -> Req:not_found()
            end;
        _ ->
            Req:respond({501, [], "Invalid HTTP method"})
    end;
handle_static(_OtherPath, Req) ->
    Req:respond({400, [], "Invalid path"}).

param(ParsedQuery, Key, DefaultValue) ->
    case lists:keysearch(Key, 1, ParsedQuery) of
        {value, {_Key, Value}} ->
            Value;
        false ->
            DefaultValue
    end.

params(ParsedQuery, Key) ->
    [V || {K, V} <- ParsedQuery, K =:= Key].

check_auth(Req, Resource, PermissionsRequired, Fun) ->
    rabbithub_auth:check_authentication
      (Req, fun (Username) ->
                    rabbithub_auth:check_authorization
                      (Req, Resource, Username, PermissionsRequired,
                       fun () ->
                               Fun(Username)
                       end)
            end).

handle_request(ResourceTypeAtom, Facet, Resource, ParsedQuery, Req) ->
    HubMode = param(ParsedQuery, "hub.mode", ""),
    Method = Req:get(method),
    case check_facet(Method, Facet, HubMode, ResourceTypeAtom) of
        {auth_required, PermissionsRequired} ->
            check_auth(Req, Resource, PermissionsRequired,
                       fun (_Username) ->
                               perform_request(Method,
                                               list_to_atom(Facet),
                                               list_to_atom(HubMode),
                                               ResourceTypeAtom,
                                               Resource,
                                               ParsedQuery,
                                               Req)
                       end);
         auth_not_required ->
            perform_request(Method,
                            list_to_atom(Facet),
                            list_to_atom(HubMode),
                            ResourceTypeAtom,
                            Resource,
                            ParsedQuery,
                            Req);
                            
        auth_required_rabbithub_admin ->
            rabbithub_auth:check_authentication_and_roles(Req, 
                                                              [administrator, rabbithub_admin],
                                                              fun (_Username) ->
                                                                perform_request(Method,
                                                                               list_to_atom(Facet),
                                                                               list_to_atom(HubMode),
                                                                               ResourceTypeAtom,
                                                                               Resource,
                                                                               ParsedQuery,
                                                                               Req)
                                                                end);            
        invalid_operation ->
            Req:respond({400, [], "Invalid operation"})
    end.

request_host(Req) ->
    case Req:get_header_value("host") of
        undefined ->
            rabbithub:canonical_host();
        V ->
            V
    end.

self_url(Req) ->
    canonical_url(Req, Req:get(path)).

canonical_url(Req, Path) ->
    mochiweb_util:urlunsplit({rabbithub:canonical_scheme(),
                              request_host(Req),
                              Path,
                              "",
                              ""}).

application_descriptor(Name, Description, Class, Parameters, Facets) ->
    {application, [{name, [Name]},
                   {description, [Description]},
                   {class, [Class]},
                   {parameters, [{parameter, [{name, N}, {value, V}], []}
                                 || {N, V} <- Parameters]},
                   {facets, Facets}]}.

desc_action(HubMode, HttpMethod, Name, Description, Params) ->
    HubModeAttr = case HubMode of
                      undefined -> [];
                      _ -> [{'hub.mode', HubMode}]
                  end,
    {action, HubModeAttr ++ [{'http.method', HttpMethod}, {name, Name}],
     [{description, [Description]} | Params]}.

desc_param(Name, Location, Attrs, Description) ->
    {parameter, [{name, Name}, {location, Location} | Attrs],
     [{description, [Description]}]}.

facet_descriptor(Name, Description, Actions) ->
    {facet, [{name, Name}],
     [{description, [Description]},
      {actions, Actions}]}.

endpoint_facet() ->
    facet_descriptor
      ("endpoint",
       "Facet permitting delivery of pubsub messages into the application.",
       [desc_action("", "PUT", "create",
                    "Create an endpoint.",
                    [desc_param("amqp.exchange_type", "query", [{defaultvalue, "fanout"},
                                                                {optional, "true"}],
                                "(When creating an exchange) Specifies the AMQP exchange type.")]),
        desc_action("", "DELETE", "destroy",
                    "Destroy the endpoint.",
                    []),
        desc_action(undefined, "POST", "deliver",
                    "Deliver a message to the endpoint.",
                    [desc_param("hub.topic", "query", [{defaultvalue, ""}],
                                "The routing key to use for the delivery."),
                     desc_param("content-type", "headers", [],
                                "The content-type of the body to deliver."),
                     desc_param("body", "body", [],
                                "The body of the HTTP request is used as the message to deliver.")]),
        desc_action("", "GET", "info",
                    "Retrieve a description of the application.",
                    []),
        desc_action("subscribe", "GET", "verify_subscription",
                    "Ensure that an earlier-generated token is valid and intended for use as a subscription token.",
                    [desc_param("hub.challenge", "query", [],
                                "Token to echo to the caller."),
                     desc_param("hub.lease_seconds", "query", [],
                                "Number of seconds that the subscription will remain active before expiring."),
                     desc_param("hub.verify_token", "query", [],
                                "The token to validate.")]),
        desc_action("unsubscribe", "GET", "verify_unsubscription",
                    "Ensure that an earlier-generated token is valid and intended for use as an unsubscription token.",
                    [desc_param("hub.challenge", "query", [],
                                "Token to echo to the caller."),
                     desc_param("hub.lease_seconds", "query", [{optional, "true"}],
                                "Number of seconds that the subscription will remain active before expiring."),
                     desc_param("hub.verify_token", "query", [],
                                "The token to validate.")]),
        desc_action("generate_token", "GET", "generate_token",
                    "Generate a verify_token for use in subscribing this application to (or unsubscribing this application from) some other application's message stream.",
                    [desc_param("hub.intended_use", "query", [],
                                "Either 'subscribe' or 'unsubscribe', depending on the intended use of the token."),
                     desc_param("rabbithub.data", "query", [{defaultvalue, ""}],
                                "Additional data to be checked during the verification stage.")])]).

subscribe_facet() ->
    facet_descriptor
      ("subscribe",
       "Facet permitting subscription to and unsubscription from pubsub messages generated by the application.",
       [desc_action("", "GET", "info",
                    "Retrieve a description of the application.",
                    []),
        desc_action("subscribe", "POST", "subscribe",
                    "Subscribe to pubsub messages from the application.",
                    [desc_param("hub.callback", "query", [],
                                "The URL to post each message to as it arrives."),
                     desc_param("hub.topic", "query", [],
                                "A filter for selecting a subset of messages. Each kind of hub interprets this parameter differently."),
                     desc_param("hub.verify", "query", [],
                                "Either 'sync' or 'async'; the subscription verification mode for this request. See the PubSubHubBub spec."),
                     desc_param("hub.verify_token", "query", [{optional, "true"}],
                                "Subscriber-provided opaque token. See the PubSubHubBub spec."),
                     desc_param("hub.lease_seconds", "query", [{optional, "true"}],
                                "Subscriber-provided lease duration request, in seconds. See the PubSubHubBub spec.")]),
        desc_action("unsubscribe", "POST", "unsubscribe",
                    "Unsubscribe from the application.",
                    [desc_param("hub.callback", "query", [],
                                "The URL that was used to subscribe."),
                     desc_param("hub.topic", "query", [],
                                "The filter that was used to subscribe."),
                     desc_param("hub.verify", "query", [],
                                "Either 'sync' or 'async'; the subscription verification mode for this request. See the PubSubHubBub spec."),
                     desc_param("hub.verify_token", "query", [{optional, "true"}],
                                "Subscriber-provided opaque token. See the PubSubHubBub spec."),
                     desc_param("hub.lease_seconds", "query", [{optional, "true"}],
                                "Subscriber-provided lease duration request, in seconds. See the PubSubHubBub spec.")])]).

declare_queue(Resource = #resource{kind = queue, name = QueueNameBin}, _ParsedQuery, Req) ->
    check_auth(Req, Resource, [configure],
               fun (_Username) ->
                       case rabbit_amqqueue:lookup(Resource) of
                           {ok, _} ->
                               Req:respond({204, [], []});
                           {error, not_found} ->
                               rabbit_amqqueue:declare(Resource, true, false, [], none),
                               QN = binary_to_list(QueueNameBin),
                               Req:respond({201,
                                            [{"Location",
                                              canonical_url(Req, "/endpoint/q/" ++ QN)}],
                                            []})
                       end
               end).

resource_exists(R) ->
    ResourceMod = case R#resource.kind of
                      exchange -> rabbit_exchange;
                      queue -> rabbit_amqqueue
                  end,
    case ResourceMod:lookup(R) of
        {ok, _} ->
            true;
        {error, not_found} ->
            false
    end.

generate_and_send_token(Req, Resource, IntendedUse, ExtraData) ->
    case resource_exists(Resource) of
        true ->
            SignedTerm = rabbithub:sign_term({Resource, IntendedUse, ExtraData}),
            Req:respond({200,
                         [{"Content-type", "application/x-www-form-urlencoded"}],
                         ["hub.verify_token=", rabbithub:b64enc(SignedTerm)]});
        false ->
            Req:not_found()
    end,
    ok.

decode_and_verify_token(EncodedParam) ->
    case catch decode_and_verify_token1(EncodedParam) of
        {'EXIT', _Reason} ->
            {error, crash};
        Other ->
            Other
    end.

decode_and_verify_token1(EncodedParam) ->
    SignedTerm = rabbithub:b64dec(EncodedParam),
    rabbithub:verify_term(SignedTerm).

check_token(Req, ActualResource, ActualUse, ParsedQuery) ->
    EncodedParam = param(ParsedQuery, "hub.verify_token", ""),
    Challenge = param(ParsedQuery, "hub.challenge", ""), %% strictly speaking, mandatory
    case decode_and_verify_token(EncodedParam) of
        {error, _Reason} ->
            Req:respond({400, [], "Bad hub.verify_token"});
        {ok, {IntendedResource, IntendedUse, _ExtraData}} ->
            if
                IntendedUse =:= ActualUse andalso IntendedResource =:= ActualResource ->
                    Req:respond({200, [], Challenge});
                true ->
                    Req:respond({400, [], "Intended use or resource does not match actual use or resource."})
            end
    end.

can_shortcut(#resource{kind = exchange}, #resource{kind = queue}) ->
    true;
can_shortcut(_, _) ->
    false.

do_validate(Callback, Topic, LeaseSeconds, ActualUse, VerifyToken) ->
    Validate = case application:get_env(rabbithub, validate_callback_on_unsubscribe) of
        {ok, false} -> false;
        {ok, true} -> true;
        {ok, _} -> true;
        undefined  -> true                                                                
    end,
    case ActualUse of
        subscribe -> 
            do_validataion(Callback, Topic, LeaseSeconds, ActualUse, VerifyToken);
        unsubscribe ->
            case Validate of
                true ->
                    do_validataion(Callback, Topic, LeaseSeconds, ActualUse, VerifyToken);
                false ->
                    ok
            end
     end.
     
do_validataion(Callback, Topic, LeaseSeconds, ActualUse, VerifyToken) ->
    case catch mochiweb_util:urlsplit(Callback) of
        {_Scheme, _NetLoc, _Path, ExistingQuery, _Fragment} ->   	%% Scheme can be http or https
           Challenge = list_to_binary(rabbithub:b64enc(rabbit_guid:binary(rabbit_guid:gen(), "c"))),
           Params0 = [{'hub.mode', ActualUse},
                      {'hub.topic', Topic},
                      {'hub.challenge', Challenge},
                      {'hub.lease_seconds', LeaseSeconds}],

           Params = case VerifyToken of
                        none -> Params0;
                         _ -> [{'hub.verify_token', VerifyToken} | Params0]
                    end,

           C = case ExistingQuery of
                   "" -> "?";
                   _  -> "&"
               end,

           URL = Callback ++ C ++ mochiweb_util:urlencode(Params),

           case httpc:request(get, {URL, []}, [], []) of
               {ok, {{_Version, StatusCode, _StatusText}, _Headers, Body}} 
                  when StatusCode >= 200 andalso StatusCode < 300 ->
                     BinaryBody = list_to_binary(Body),
                     if
                        Challenge =:= BinaryBody ->
                            ok;
                        true ->
                            {error, challenge_mismatch}
                     end;
               {ok, {{_Version, StatusCode, _StatusText}, _Headers, _Body}} ->
                   {error, {request_status, StatusCode}};
               {error, Reason} ->
                   {error, Reason}
            end;
        _ ->
            {error, invalid_callback_url}
    end.


invoke_sub_fun_and_respond(Req, Fun, Callback, Topic, LeaseSeconds, MaybeShortcut) ->
    case Fun(Callback, Topic, LeaseSeconds, MaybeShortcut) of
        ok ->
            Req:respond({204, [], []});
        {ok, Body} ->
            Req:respond({201, [{"Content-Type", "text/html"}], Body});
        {error, {status, StatusCode}} ->
            Req:respond({StatusCode, [], []});
        {error, {status, StatusCode}, Reason} ->
            Req:respond({StatusCode, [], Reason})
    end.
    

first_acceptable(_Predicate, []) ->    
    {error, none_acceptable};
first_acceptable(Predicate, [Candidate | Rest]) ->
    case Predicate(Candidate) of
        true ->
            ok;
        false ->
            first_acceptable(Predicate, Rest)
    end.

extract_verify_modes(ParsedQuery, ValueIfMissing) ->
    case lists:concat([string:tokens(V, ",") || V <- params(ParsedQuery, "hub.verify")]) of
        [] -> ValueIfMissing;
        Modes -> Modes
    end.

extract_lease_seconds(ParsedQuery) ->
    case catch list_to_integer(param(ParsedQuery, "hub.lease_seconds", "")) of
        {'EXIT', _Reason} ->
            ?DEFAULT_SUBSCRIPTION_LEASE_SECONDS;
        InvalidValue when InvalidValue =< 0 ->
            ?DEFAULT_SUBSCRIPTION_LEASE_SECONDS;
        InvalidValue when InvalidValue >= ?SUBSCRIPTION_LEASE_LIMIT ->
            ?SUBSCRIPTION_LEASE_LIMIT;
        Value ->
            Value
    end.
    
extract_maxtps(ParsedQuery) ->
    case catch list_to_integer(param(ParsedQuery, "hub.maxtps", 0)) of
        {'EXIT', _Reason} -> 0;
        InvalidValue when InvalidValue =< 0 -> 0;
        Value -> Value
    end.
        
%%subscribing or unsubscribing a subscription does require the subscriber to be available
validate_subscription_request(Req, ParsedQuery, SourceResource, ActualUse, Fun) ->
    Callback = param(ParsedQuery, "hub.callback", missing),
    Topic = param(ParsedQuery, "hub.topic", missing),
    VerifyModes = extract_verify_modes(ParsedQuery, missing),
    VerifyToken = param(ParsedQuery, "hub.verify_token", none),
    LeaseSeconds = extract_lease_seconds(ParsedQuery),
    case lists:member(missing, [Callback, Topic, VerifyModes]) of
        true ->
            Req:respond({400, [], "Missing required parameter"});
        false ->
            case decode_and_verify_token(VerifyToken) of
                {ok, {TargetResource, IntendedUse, _ExtraData}} -> 
                    %% OMG it's one of ours! It could be possible to
                    %% shortcut.
                    case IntendedUse of
                        ActualUse ->
                            case can_shortcut(SourceResource, TargetResource) of                      
                                true ->
                                    invoke_sub_fun_and_respond(Req, Fun,
                                                               Callback, Topic, LeaseSeconds,
                                                               TargetResource);
                                false ->
                                    invoke_sub_fun_and_respond(Req, Fun,
                                                               Callback, Topic, LeaseSeconds,
                                                               no_shortcut)
                            end;
                        _ ->
                            Req:respond({400, [], "Shortcut token has wrong hub.mode"})
                    end;
                {error, _} ->
                    %% Either it's not ours, or it's corrupted in some
                    %% way. No short-cuts are possible. Treat it as a
                    %% regular subscription request and invoke the
                    %% verification callback.
                    case first_acceptable(
                           fun ("async") ->
                                   Req:respond({202, [], []}),
                                   spawn(fun () ->
                                                 case do_validate(Callback, Topic, LeaseSeconds,
                                                                  ActualUse, VerifyToken) of
                                                     ok ->
                                                         Fun(Callback, Topic, LeaseSeconds,
                                                             no_shortcut);
                                                     {error, _} ->
                                                         ignore
                                                 end
                                         end),
                                   true;
                               ("sync") ->
                                   case do_validate(Callback, Topic, LeaseSeconds,
                                                    ActualUse, VerifyToken) of
                                       ok ->
                                           invoke_sub_fun_and_respond(Req, Fun,
                                                                      Callback, Topic, LeaseSeconds,
                                                                      no_shortcut);
                                       {error, Reason} ->
                                           Req:respond
                                             ({400, [],
                                               io_lib:format("Request verification failed: ~p",
                                                             [Reason])})
                                   end,
                                   true;
                               (_) ->
                                   false
                           end, VerifyModes) of
                        ok ->
                            ok;
                        {error, none_acceptable} ->
                            Req:respond({400, [], "No supported hub.verify modes listed"})
                    end
            end
    end.
    


% QueryString hub.persistmsg = 0 or false, DeliveryMode = 1 -> non-persistent message
% QueryString hub.persistmsg = 1 or true , DeliveryMode = 2 -> persistent message (saved to disk)
% If hub.persistmsg is anything other than 0/false or 1/true then assume non-persistent, but log 
% the fact that an invalid value was supplied.
get_msg_delivery_mode(PersistMsg) ->
   case PersistMsg of
        "1" -> 2;
        "0" -> 1;
        "true"  -> 2;
        "false" -> 1;
         _ -> 
            rabbit_log:info("RabbitHub received invalid delivery mode option: ~p~n", [PersistMsg]),
            1
   end.

                         
extract_message(ExchangeResource, ParsedQuery, MsgId, CorrId, Req) ->
    RoutingKey = param(ParsedQuery, "hub.topic", ""),
    DeliveryMode = get_msg_delivery_mode(param(ParsedQuery, "hub.persistmsg", "0")),
    ContentTypeBin = case Req:get_header_value("content-type") of
                         undefined -> undefined;
                         S -> list_to_binary(S)
                     end,
    Body = Req:recv_body(),
%%  rabbit_log:info("RabbitHub message delivery mode: ~p~n", [DeliveryMode]),
    AllProps = case {MsgId, CorrId} of
        {undefined, undefined} ->
            [{'content_type', ContentTypeBin},{'delivery_mode',DeliveryMode}];
        {MId, undefined} -> 
            [{'content_type', ContentTypeBin},{'delivery_mode',DeliveryMode}, {'message_id', MId}];
        {undefined, CId} -> 
            [{'content_type', ContentTypeBin},{'delivery_mode',DeliveryMode}, {'correlation_id', CId}];
        {MId, CId} -> 
            [{'content_type', ContentTypeBin},{'delivery_mode',DeliveryMode}, {'message_id', MId}, {correlation_id, CId}]
    end,     
    rabbit_basic:message(ExchangeResource,
                         list_to_binary(RoutingKey),
                         AllProps,
                         Body).
                         
                         
%% GF: function to add custom message properties to msg
extract_message(ExchangeResource, ParsedQuery, PropList, MsgId, CorrId, Req) ->
    RoutingKey = param(ParsedQuery, "hub.topic", ""),
    DeliveryMode = get_msg_delivery_mode(param(ParsedQuery, "hub.persistmsg", "0")),
    ContentTypeBin = case Req:get_header_value("content-type") of
                         undefined -> undefined;
                         S -> list_to_binary(S)
                     end,
    Body = Req:recv_body(),    
    HeaderList = [{headers, PropList}],       
    AllProps = case {MsgId, CorrId} of
        {undefined, undefined} ->
            lists:append([[{'content_type', ContentTypeBin},{'delivery_mode',DeliveryMode}],HeaderList]);
        {MId, undefined} -> 
            lists:append([[{'content_type', ContentTypeBin},{'delivery_mode',DeliveryMode}, {'message_id', MId}],HeaderList]);
        {undefined, CId} -> 
            lists:append([[{'content_type', ContentTypeBin},{'delivery_mode',DeliveryMode}, {'correlation_id', CId}],HeaderList]);
        {MId, CId} -> 
            lists:append([[{'content_type', ContentTypeBin},{'delivery_mode',DeliveryMode}, {'message_id', MId}, {'correlation_id', CId}],HeaderList])
    end,          
    rabbit_basic:message(ExchangeResource,
                         list_to_binary(RoutingKey),
                         AllProps,
                         Body).
                         
%% GF: function to convert list of http post errors from database to JSON
convert_errors_to_json(Errors) ->
    Data = {struct, [{errors, [
              [{resource, element(2,(Error#rabbithub_subscription_err.subscription)#rabbithub_subscription.resource)},
               {queue, element(4,(Error#rabbithub_subscription_err.subscription)#rabbithub_subscription.resource)},
               {topic, list_to_binary((Error#rabbithub_subscription_err.subscription)#rabbithub_subscription.topic)},
               {callback, list_to_binary((Error#rabbithub_subscription_err.subscription)#rabbithub_subscription.callback)},
               {error_count, Error#rabbithub_subscription_err.error_count},
               {first_error_time_microsec, Error#rabbithub_subscription_err.first_error_time_microsec},
               {last_error_time_microsec, Error#rabbithub_subscription_err.last_error_time_microsec},
               {last_error_msg, list_to_binary(lists:flatten(io_lib:format("~p", [[Error#rabbithub_subscription_err.last_error_msg]])))}]
	    || Error <- Errors]}]},
    Resp = mochijson2:encode(Data),
    Resp.

convert_amq_to_binary(Amq) ->
    Flat = lists:flatten(io_lib:format("~p", [[Amq]])),
    AmqString = re:replace(re:replace(Flat, "\n", "", [global,{return,list}]), "\s{2,}", " ", [global,{return,list}]),
    AmqBinary = list_to_binary(AmqString),
    AmqBinary.

%% GF: function to convert list of leases from database to JSON

convert_leases_to_json(Leases) ->
    Data = {struct,  [{subscriptions, [
              [{vhost, element(2,(Lease#rabbithub_lease.subscription)#rabbithub_subscription.resource)},              	              
               {resource_type, element(3,(Lease#rabbithub_lease.subscription)#rabbithub_subscription.resource)},
               {resource_name, element(4,(Lease#rabbithub_lease.subscription)#rabbithub_subscription.resource)}, 	     
               {topic, list_to_binary((Lease#rabbithub_lease.subscription)#rabbithub_subscription.topic)},
               {callback, list_to_binary((Lease#rabbithub_lease.subscription)#rabbithub_subscription.callback)},
               {lease_expiry_time_microsec, Lease#rabbithub_lease.lease_expiry_time_microsec},
               {lease_seconds, Lease#rabbithub_lease.lease_seconds},
               {ha_mode, Lease#rabbithub_lease.ha_mode},
               {status, Lease#rabbithub_lease.status},
               {pseudo_queue, convert_amq_to_binary(Lease#rabbithub_lease.pseudo_queue)}]
	    || Lease <- Leases]}]},
    Resp = mochijson2:encode(Data),
    Resp.

%% GF: function to convert header value into a proplist
proplist_from_options( Options ) ->
        NewOptions = re:replace(Options, "\\s+", "", [global,{return,list}]),
        Props = string:tokens( NewOptions, ", " ), % should give you ["abc=12343","someThing=value"]
        Fun = fun (Prop) -> [Name,Value] = string:tokens( Prop, "=" ), {erlang:list_to_binary( Name ),longstr, list_to_binary(Value)} end,
        lists:map( Fun, Props ).    
            
find_and_get_element(List, Key, ElementPos) ->
    case lists:keyfind(Key, 1, List) of
        false -> undefined;
        Other -> (element(ElementPos, Other))
    end.
        
manage_validation(SubscriptionTuple, TableId) ->
%% TODO add validation to all values and check for required values.
    Callback = binary_to_list(element(2, lists:keyfind(<<"callback">>, 1, element(2, SubscriptionTuple)))),
    Topic = binary_to_list(element(2, lists:keyfind(<<"topic">>, 1, element(2, SubscriptionTuple)))),
    LeaseMicro = element(2, lists:keyfind(<<"lease_expiry_time_microsec">>, 1, element(2, SubscriptionTuple))),
    Lease_Micro_Less_ST = LeaseMicro - rabbithub_subscription:system_time(),
    
    Vhost = element(2, lists:keyfind(<<"vhost">>, 1, element(2, SubscriptionTuple))),
    ResourceType = binary_to_atom(element(2, lists:keyfind(<<"resource_type">>, 1, element(2, SubscriptionTuple))), latin1),
    ResourceName = element(2, lists:keyfind(<<"resource_name">>, 1, element(2, SubscriptionTuple))),
    
    Status = find_and_get_element(element(2, SubscriptionTuple), <<"status">>, 2),
    Status2 = case Status of
        undefined -> undefined;
        BinStatus when is_binary(BinStatus) -> binary_to_atom(BinStatus, latin1)
    end,
    %%illegal status values are converted to inactive, the record will be inserted but the callback will not be validated.
    %%  validation will occur when the subscription is activated.
    Stat = case Status2 of
        undefined -> active;
        active -> active;
        inactive -> inactive;
        _BadStatus -> inactive        
    end,
    
    HA = find_and_get_element(element(2, SubscriptionTuple), <<"ha_mode">>, 2),
    HA2 = case HA of
        undefined -> undefined;
        BinHA when is_binary(BinHA) -> binary_to_atom(BinHA, latin1);
        IntHA when is_integer(IntHA) -> IntHA
    end,
    HA3 = case is_valid_ha_mode(HA2) of
        true -> HA2;
        false -> undefined
    end, 
    
    LS = find_and_get_element(element(2, SubscriptionTuple), <<"lease_seconds">>, 2),
    LS2 = case LS of
        undefined -> undefined;        
        IntLS when is_integer(IntLS) -> IntLS;
        _OtherLS -> undefined
    end,
    LeaseSeconds = case LS2 of
        undefined ->  Lease_Micro_Less_ST div 1000000;
        LS3 -> LS3
    end,
    
    MaxTps = find_and_get_element(element(2, SubscriptionTuple), <<"maxtps">>, 2),
    MaxTps2 = case MaxTps of
        undefined -> 0;
        N when is_integer(N) -> N;
        _Other -> 0
    end,
%% TODO add error handling for all properties
%%    case lists:member(false, [Callback, Topic, LeaseSeconds, Vhost, ResourceType, ResourceName]) of
%%        true ->                
%%        false ->
    
    Resource = #resource{virtual_host = Vhost, kind = ResourceType, name = ResourceName},
    Subscription = #rabbithub_subscription{resource = Resource, topic = Topic, callback = Callback},
    BatchRecordStatus = case Stat of
        active ->        
            case do_validate(Callback, Topic, LeaseSeconds, subscribe, none) of
                ok -> 
                    create_subscription(Callback, Topic, LeaseSeconds, Resource, Stat, HA3, MaxTps2);
                {error, Reason} -> 
                    ReasonString = lists:flatten(io_lib:format("~p", [{error, Reason}])),
                    ReasonString2 = re:replace(re:replace(ReasonString, "\n", "", [global,{return,list}]), "\s{2,}", " ", [global,{return,list}]),
                    [{node(), list_to_binary(ReasonString2)}]        
            end;
        inactive -> %insert record but do not validate callback url        
            create_subscription(Callback, Topic, LeaseSeconds, Resource, Stat, HA3, MaxTps)
    end,  
    {atomic, CurrentLeaseList} = mnesia:transaction(fun () -> mnesia:read({rabbithub_lease, Subscription}) end),  
    CurrentLease = lists:nth(1, CurrentLeaseList),
        
    BatchRecord  = #rabbithub_batch{subscription = Subscription, 
                        lease_expiry_time_microsec = CurrentLease#rabbithub_lease.lease_expiry_time_microsec, 
                        status = BatchRecordStatus},
    ets:insert(TableId, BatchRecord).      

%% GF:  create_subscription calls the create function in rabbithub_subscription and starts the lease
create_subscription(Callback, Topic, LeaseSeconds, Resource, Status, HA, MaxTps) ->
    Sub = #rabbithub_subscription{resource = Resource,
                                topic = Topic,
                                callback = Callback},
    HAMode = case HA of
        undefined ->
            case application:get_env(rabbithub, ha_consumers) of
                {ok, Mode} -> Mode;                                                                
                undefined  -> none                                                                
            end;
         OtherModes -> OtherModes
    end, 
    
    case rabbithub_subscription:create(Sub, LeaseSeconds, HAMode, MaxTps, Status) of
        %% add active inactive check, do not start subs if inactive, shutdown if existing.
        ok ->   
            case Status of
                active ->       
                    case HAMode of
                        none -> [{node(), ok}];
                        _Mode1 ->
                            Nodes = get_nodes(HAMode),
                            RPCRes = create_ha_consumers(Nodes, Sub, LeaseSeconds, HAMode, MaxTps, active),
                            Body = [{node(), ok}] ++ RPCRes,
                            Body
                    end;        
                inactive ->
                    %% check for existing consumers and stop them if they are running
                    ExistingConsumers = find_existing_consumers(Sub),
                    case ExistingConsumers of 
                        [] ->   
                            [{node(), ok}];
                        _ConsumerList ->
                            %% deactivate consumers
                            RPCRes = deactivate_ha_consumers(Sub),
                            Body = RPCRes,
                            Body
                    end
            end;
        {error, not_found} -> 
            ReasonString = lists:flatten(io_lib:format("~p", [{error, not_found}])),          
            [{node(), list_to_binary(ReasonString)}];
        {error, Reason} -> 
            ReasonString = lists:flatten(io_lib:format("~p", [{error, Reason}])),
            ReasonString2 = re:replace(re:replace(ReasonString, "\n", "", [global,{return,list}]), "\s{2,}", " ", [global,{return,list}]),
            [{node(), list_to_binary(ReasonString2)}] 
    end.

find_existing_consumers(Subscription) ->    
    Con = #consumer{subscription = Subscription, node = '_'},
    WildPattern = mnesia:table_info(rabbithub_subscription_pid, wild_pattern),
    Pattern = WildPattern#rabbithub_subscription_pid{consumer = Con},
    F = fun() -> mnesia:match_object(Pattern) end,   
    {atomic, Results} = mnesia:transaction(F),
    Results.
        
%% GF:  Batch process list of subscriptions
batch_process_subscriptions(BatchTuple) ->
    SubList = element(2, lists:nth(1, element(2, BatchTuple))),
    TableName = rabbithub_batch,
    TableId = ets:new(TableName, [set, {keypos, 2}]),
    
    lists:foreach(fun(N) ->
                      manage_validation(N, TableId)
                  end, SubList),
                  
    BatchTab = ets:tab2list(TableId),                     
    BatchTab.
    
%% GF: function to convert batch responses to JSON	    
%%    BatchRecord  = #rabbithub_batch{subscription = Subscription, lease_expiry_time_microsec = LeaseSeconds, status = BatchRecordStatus},
convert_batch_response_body_to_json(Body) ->           
    Data = {struct,  [{rabbithub_batch_results, [
              [{vhost, element(2,(B#rabbithub_batch.subscription)#rabbithub_subscription.resource)},              	              
               {resource_type, element(3,(B#rabbithub_batch.subscription)#rabbithub_subscription.resource)},
               {resource_name, element(4,(B#rabbithub_batch.subscription)#rabbithub_subscription.resource)}, 	     
               {topic, list_to_binary((B#rabbithub_batch.subscription)#rabbithub_subscription.topic)},
               {callback, list_to_binary((B#rabbithub_batch.subscription)#rabbithub_subscription.callback)},
               {lease_expiry_time_microsec, B#rabbithub_batch.lease_expiry_time_microsec},
               {status, convert_response_body_to_tuple(B#rabbithub_batch.status)}]
	    || B <- Body]}]},
    Resp = mochijson2:encode(Data),
    Resp.

convert_response_body_to_tuple(Body) ->
    Data = {struct,  [{consumers, [
              [{node, element(1, B)},
               {status, element(2,B)}]
	    || B <- Body]}]},
    Data.   

%% GF: GET current errors for each subscription
perform_request('GET', subscriptions, '', errors, _Resource, _ParsedQuery, Req) ->
     {atomic, Errors} =
        mnesia:transaction(fun () ->
                                   mnesia:foldl(fun (Error, Acc) -> [Error | Acc] end,
                                                [],
                                                rabbithub_subscription_err)
                           end),
     Json = convert_errors_to_json(Errors),
     Req:respond({200, [{"Content-Type", "application/json"}], Json });
     

%% GF: GET subscriptions returns a list of all leases in the database
perform_request('GET', subscriptions, '', none, _Resource, _ParsedQuery, Req) ->
     {atomic, Leases} =
        mnesia:transaction(fun () ->
                                   mnesia:foldl(fun (Lease, Acc) -> [Lease | Acc] end,
                                                [],
                                                rabbithub_lease)
                           end),                          
     Json = convert_leases_to_json(Leases),
     Req:respond({200, [{"Content-Type", "application/json"}], Json });
     
%% GF:  New endpoint to upload Subscriptions in batch
perform_request('POST', subscriptions, '', none, _Resource, _ParsedQuery, Req) ->    
     Body = Req:recv_body(), 
     try mochijson2:decode(Body) of
         DecodedBody ->             
             Resp = batch_process_subscriptions(DecodedBody),      
             RespJson = convert_batch_response_body_to_json(Resp),
             Req:respond({202, [{"Content-Type", "application/json"}], RespJson})
     catch
         _:_ -> Req:respond({400, [], "invalide json"})
     end;
     
     

%% GF: Updated to handle message headers for header exchange POSTs
perform_request('POST', endpoint, '', exchange, Resource, ParsedQuery, Req) ->
    MsgId = case application:get_env(rabbithub, set_message_id) of
        {ok, _MsgIDHeaderName} -> 
            rabbit_guid:binary(rabbit_guid:gen(), "rabbithub_msgid");
        _ ->
            undefined
    end,
    CorrId =  case application:get_env(rabbithub, set_correlation_id) of
        {ok, CorrIdHeaderName} -> 
            case Req:get_header_value(CorrIdHeaderName) of
                undefined -> undefined;
                HV -> list_to_binary(HV)
            end;
        _ -> undefined
    end,         
            
    case MsgId of
        undefined -> do_nothing;
        MsgIdValue ->  rabbit_log:info("RabbitHub:  Message Published for Resource ~p~n with message id: ~p~n", [Resource, MsgIdValue])
    end,
    case CorrId of
        undefined -> do_nothing;
        CorrIdValue -> rabbit_log:info("RabbitHub:  Message Published for Resource ~p~n with correlation id: ~p~n", [Resource, CorrIdValue])
    end,
    case application:get_env(rabbithub, log_http_headers) of
        {ok, HeaderList} ->
            lists:foreach(fun(N) -> 
                case Req:get_header_value(N) of        
                    undefined -> do_nothing;
                    HeaderValue ->  rabbit_log:info("RabbitHub:  Message Published for Resource ~p~n with HTTP Header: ~p = ~p~n", 
                                        [Resource, N, HeaderValue])
                end
                end, HeaderList);
        _ ->
            do_nothing
    end,
    case Req:get_header_value("x-rabbithub-msg_header") of
        %% no custom HTTP header for headers exchange, publish normal
        undefined ->            
            Msg = extract_message(Resource, ParsedQuery, MsgId, CorrId, Req),
	        Delivery = rabbit_basic:delivery(false, false, Msg, undefined),
	        case rabbit_basic:publish(Delivery) of
		        {ok,  _A} ->
		            Req:respond({202, [], []});
		        {error, not_found} ->
		            Req:respond({404, [], "exchange not found"})
	        end;
	    %% Custom Header for Headers exchange exists, convert header to message properties
        CustHeaderProps ->
             Proplist = proplist_from_options(CustHeaderProps),
	         Msg = extract_message(Resource, ParsedQuery, Proplist, MsgId, CorrId, Req),
	         Delivery = rabbit_basic:delivery(false, false, Msg, undefined),
	         case rabbit_basic:publish(Delivery) of
		     {ok,  _} ->
	     	     Req:respond({202, [], []});
		     {error, not_found} ->
		         Req:not_found()
	         end
    end;

perform_request('POST', endpoint, '', queue, Resource, ParsedQuery, Req) ->

    MsgId = case application:get_env(rabbithub, set_message_id) of
        {ok, _MsgIDHeaderName} -> 
            rabbit_guid:binary(rabbit_guid:gen(), "rabbithub_msgid");
        _ ->
            undefined
    end,
    CorrId =  case application:get_env(rabbithub, set_correlation_id) of
        {ok, CorrIdHeaderName} -> 
            case Req:get_header_value(CorrIdHeaderName) of
                undefined -> undefined;
                HV -> list_to_binary(HV)
            end;
        _ -> undefined
    end,            
    case MsgId of
        undefined -> do_nothing;
        MsgIdValue -> rabbit_log:info("RabbitHub: Message Published for Resource ~p~n with message_id = ~p~n", [Resource, MsgIdValue])
    end,
    case CorrId of
        undefined -> do_nothing;
        CorrIdValue -> rabbit_log:info("RabbitHub: Message Published for Resource ~p~n with correlation_id = ~p~n", [Resource, CorrIdValue])
    end,
    case application:get_env(rabbithub, log_http_headers) of
        {ok, HeaderList} ->
            lists:foreach(fun(N) -> 
                                case Req:get_header_value(N) of        
                                    undefined -> do_nothing;
                                    HeaderValue ->  rabbit_log:info("RabbitHub: Message Published for Resource ~p~n with HTTP Header ~p = ~p~n", 
                                        [Resource, N, HeaderValue])
                                end
                            end, HeaderList);
        _ ->
            do_nothing
    end,

    Msg = extract_message(rabbithub:r(exchange, ""), ParsedQuery, MsgId, CorrId, Req),
    Delivery = rabbit_basic:delivery(false, false, Msg, undefined),
    case rabbit_amqqueue:lookup([Resource]) of
        [Queue] ->
            _QPids = rabbit_amqqueue:deliver([Queue], Delivery),
            Req:respond({202, [], []});
        [] ->
            Req:not_found()
    end;

perform_request('PUT', endpoint, '', exchange, Resource, ParsedQuery, Req) ->
    ExchangeTypeBin = list_to_binary(param(ParsedQuery, "amqp.exchange_type", "fanout")),
    case catch rabbit_exchange:check_type(ExchangeTypeBin) of
        {'EXIT', _} ->
            Req:respond({400, [], "Invalid exchange type"});
        ExchangeType ->
            case rabbit_exchange:lookup(Resource) of
                {ok, _} ->
                    Req:respond({204, [], []});
                {error, not_found} ->
                    rabbit_exchange:declare(Resource, ExchangeType, true, false, false, []),
                    Req:respond({201, [{"Location", self_url(Req)}], []})
            end
    end;

perform_request('PUT', endpoint, '', queue, UncheckedResource, ParsedQuery, Req) ->
    case UncheckedResource of
        #resource{kind = queue, name = <<>>} ->
            V = rabbithub:r(queue, rabbit_guid:binary(rabbit_guid:gen(), "amq.gen.http")),
            declare_queue(V, ParsedQuery, Req);
        %% FIXME should use rabbit_channel:check_name/2, but that's not exported:
        #resource{kind = queue, name = <<"amq.", _/binary>>} ->
            Req:respond({400, [], "Invalid queue name"});
        V ->
            declare_queue(V, ParsedQuery, Req)
    end;

perform_request('DELETE', endpoint, '', exchange, Resource, _ParsedQuery, Req) ->
    case Resource of
        #resource{kind = exchange, name = <<>>} ->
            Req:respond({403, [], "Deleting the default exchange is not permitted"});
        _ ->
            case rabbit_exchange:delete(Resource, false) of
                {error, not_found} ->
                    Req:not_found();
                ok ->
                    Req:respond({204, [] ,[]})
            end
    end;

perform_request('DELETE', endpoint, '', queue, Resource, _ParsedQuery, Req) ->
    case rabbit_amqqueue:lookup(Resource) of
        {error, not_found} ->
            Req:not_found();
        {ok, Q} ->
            {ok, _PurgedMessageCount} = rabbit_amqqueue:delete(Q, false, false),
            Req:respond({204, [] ,[]})
    end;

perform_request('GET', Facet, '', exchange, Resource, _ParsedQuery, Req) ->
    case rabbit_exchange:lookup(Resource) of
        {error, not_found} ->
            Req:not_found();
        {ok, #exchange{name = #resource{kind = exchange, name = XNameBin},
                       type = Type}} ->
            XN = binary_to_list(XNameBin),
            Xml = application_descriptor(XN,
                                         "AMQP " ++ rabbit_misc:rs(Resource),
                                         "amqp.exchange",
                                         [{"amqp.exchange_type", atom_to_list(Type)}],
                                         [case Facet of
                                              endpoint -> endpoint_facet();
                                              subscribe -> subscribe_facet()
                                          end]),
            rabbithub:respond_xml(Req, 200, [], ?APPLICATION_XSLT, Xml)
    end;

perform_request('GET', Facet, '', queue, Resource, _ParsedQuery, Req) ->
    case rabbit_amqqueue:lookup(Resource) of
        {error, not_found} ->
            Req:not_found();
        {ok, #amqqueue{name = #resource{kind = queue, name = QNameBin}}} ->
            QN = binary_to_list(QNameBin),
            Xml = application_descriptor(QN,
                                         "AMQP " ++ rabbit_misc:rs(Resource),
                                         "amqp.queue",
                                         [],
                                         [case Facet of
                                              endpoint -> endpoint_facet();
                                              subscribe -> subscribe_facet()
                                          end]),
            rabbithub:respond_xml(Req, 200, [], ?APPLICATION_XSLT, Xml)
    end;

perform_request('GET', endpoint, generate_token, _ResourceTypeAtom, Resource, ParsedQuery, Req) ->
    ExtraData = param(ParsedQuery, "rabbithub.data", ""),
    case param(ParsedQuery, "hub.intended_use", undefined) of
        "subscribe" ->
            ok = generate_and_send_token(Req, Resource, subscribe, ExtraData);
        "unsubscribe" ->
            ok = generate_and_send_token(Req, Resource, unsubscribe, ExtraData);
        _ ->
            Req:respond({400, [], "Missing or bad hub.intended_use parameter"})
    end;

perform_request('GET', endpoint, subscribe, _ResourceTypeAtom, Resource, ParsedQuery, Req) ->
    check_token(Req, Resource, subscribe, ParsedQuery);

perform_request('GET', endpoint, unsubscribe, _ResourceTypeAtom, Resource, ParsedQuery, Req) ->
    check_token(Req, Resource, unsubscribe, ParsedQuery);

perform_request('POST', subscribe, '', ResourceTypeAtom, Resource, _ParsedQuery, Req) ->
    %% Pulls new query parameters out of the body, and loops around to
    %% handle_request again, which performs authentication and
    %% authorization checks as appropriate to the new query
    %% parameters.

    IsContentTypeOk = case Req:get_header_value("content-type") of
                          undefined -> true; %% permit people to omit it
                          "application/x-www-form-urlencoded" -> true;
                          _ -> false
                      end,
    if
        IsContentTypeOk ->
            BodyQuery = mochiweb_util:parse_qs(Req:recv_body()),
            handle_request(ResourceTypeAtom, "subscribe", Resource, BodyQuery, Req);
        true ->
            Req:respond({400, [], "Bad content-type; expected application/x-www-form-urlencoded"})
    end;

perform_request('POST', subscribe, subscribe, _ResourceTypeAtom, Resource, ParsedQuery, Req) ->
    Cont = case Resource#resource.kind of
        queue ->
            case rabbit_amqqueue:lookup(Resource) of
                {error, not_found} -> 
                    Req:respond({404, [{"Content-Type", "text/html"}], "queue or exchange not found"}),
                    error;
                {ok, _Q} -> ok
             end;
         exchange ->
             case rabbit_exchange:lookup(Resource) of
                {ok, _} -> ok;                    
                {error, not_found} -> 
                    Req:respond({404, [{"Content-Type", "text/html"}], "queue or exchange not found"}),
                    error
             end
    end,
    case Cont of
        ok ->
            validate_subscription_request(Req, ParsedQuery, Resource, subscribe,
                                  fun (Callback, Topic, LeaseSeconds, no_shortcut) ->
                                    Sub = #rabbithub_subscription{resource = Resource,
                                                                    topic = Topic,
                                                                    callback = Callback},
                                    HubHAConsumer = param(ParsedQuery, "hub.haconsumer", true),
                                    HAMode = case HubHAConsumer of
                                        true ->
                                            case application:get_env(rabbithub, ha_consumers) of
                                                {ok, Mode} -> Mode;                                                                
                                                _ -> none                                                                
                                            end;
                                         false -> none
                                    end,                                                       
                                    MaxTps = extract_maxtps(ParsedQuery),     
                                    case rabbithub_subscription:create(Sub, LeaseSeconds, HAMode, MaxTps, active) of
                                        ok ->                                             
                                            case HubHAConsumer of
                                                true ->
                                                    case HAMode of
                                                        none -> ok;
                                                        _Mode1 ->
                                                            Nodes = get_nodes(HAMode),
                                                            RPCRes = create_ha_consumers(Nodes, Sub, LeaseSeconds, HAMode, MaxTps, active),
                                                            Body = [{node(), ok}] ++ RPCRes,
                                                            ResponseBody = convert_response_body_to_json(Body),
                                                            {ok, ResponseBody}
                                                    end;
                                                 false -> ok
                                            end;                
                                        {error, not_found} -> {error, {status, 404}, "queue or exchange not found"};
                                        {error, _} ->         {error, {status, 500}};
                                        Err ->                {error, {status, 400}, lists:flatten(io_lib:format("~p", [Err]))}
                                    end;
                                    (_Callback, Topic, _LeaseSeconds, TargetResource) ->
                                      case rabbit_binding:add(
                                             #binding{source      = Resource,
                                                      destination = TargetResource,
                                                      key         = list_to_binary(Topic),
                                                      args        = []}) of
                                          ok ->
                                              ok;
                                          {error, _} ->
                                              {error, {status, 404}}
                                      end
                                end);
        _ -> do_nothing                                                                
    end;                          

perform_request('POST', subscribe, unsubscribe, _ResourceTypeAtom, Resource, ParsedQuery, Req) ->
    validate_subscription_request(Req, ParsedQuery, Resource, unsubscribe,
                                  fun (Callback, Topic, _LeaseSeconds, no_shortcut) ->
                                        Sub = #rabbithub_subscription{resource = Resource,
                                                                        topic = Topic,
                                                                        callback = Callback},
                                        case rabbithub_subscription:deactivate(Sub) of
                                              ok -> 
                                                case application:get_env(rabbithub, ha_consumers) of
                                                    {ok, _Mode} ->
                                                        %Nodes = get_nodes(Mode),
                                                        RPCRes = deactivate_ha_consumers(Sub),
                                                        Body = [{node(), ok}] ++ RPCRes,
                                                        ResponseBody = convert_response_body_to_json(Body),
                                                        {ok, ResponseBody};
                                                    _ ->                                              
                                                        ok
                                                end;
                                              {error, not_found} -> {error, {status, 404}};
                                              {error, Reason} ->
                                                  rabbit_log:warning("RabbitHub 500 Error during Delete of ~p~n Error: ~p~n", [Sub, Reason]), 
                                                  {error, {status, 500}} 
                                          end;
                                      (_Callback, Topic, _LeaseSeconds, TargetResource) ->
                                          case rabbit_binding:remove(
                                                 #binding{source      = Resource,
                                                          destination = TargetResource,
                                                          key         = list_to_binary(Topic),
                                                          args        = []}) of
                                              ok ->
                                                  ok;
                                              {error, _} ->                                                   
                                                  {error, {status, 404}}
                                          end
                                  end);
%%delete subscription does not require subscriber to be available                                   
perform_request('DELETE', subscribe, _HubMode, _ResourceTypeAtom, Resource, ParsedQuery, Req) ->
    Callback = param(ParsedQuery, "hub.callback", missing),
    Topic = param(ParsedQuery, "hub.topic", missing),
    case lists:member(missing, [Callback, Topic]) of
        true ->
            Req:respond({400, [], "Missing required parameter"});
        false ->
            Sub = #rabbithub_subscription{resource = Resource,
                                            topic = Topic,
                                            callback = Callback},
            {atomic, Lease} = mnesia:transaction(fun () -> mnesia:read({rabbithub_lease, Sub}) end),
            case Lease of
                [] ->  Req:respond({400, [], "Subscription not found please validate parameters"});
                [L1] ->
                    case L1#rabbithub_lease.ha_mode of
                        [] -> delete_subscription(Req, Sub, none);
                        undefined -> delete_subscription(Req, Sub, none);
                        none -> delete_subscription(Req, Sub, none);
                        _HAMode -> 
                            RPCRes = deactivate_ha_consumers(Sub),
                            delete_subscription(Req, Sub, RPCRes)
                    end       
            end
    end;                                      

                        

perform_request(Method, Facet, HubMode, _ResourceType, Resource, ParsedQuery, Req) ->
    Xml = {debug_request_echo, [{method, [atom_to_list(Method)]},
                                {facet, [atom_to_list(Facet)]},
                                {hubmode, [atom_to_list(HubMode)]},
                                {resource, [rabbit_misc:rs(Resource)]},
                                {querystr, [io_lib:format("~p", [ParsedQuery])]}]},
    rabbit_log:info("RabbitHub performing request ~p~n", [Xml]),
    rabbithub:respond_xml(Req, 200, [], none, Xml).
%% end of perform_request functions    
    
delete_subscription(Req, Sub, RPCRes) ->
    case rabbithub_subscription:delete(Sub) of
        ok ->
            Body = case RPCRes of
                none -> [{node(), ok}];
                Results -> RPCRes
            end,
            ResponseBody = convert_response_body_to_json(Body),
            Req:respond({200, [{"Content-Type", "application/json"}], ResponseBody }),
            {ok, ResponseBody};
        {error, not_found} -> 
            Body3 = [{node(), not_found}],
            ResponseBody3 = convert_response_body_to_json(Body3),
            Req:respond({404, [{"Content-Type", "application/json"}], ResponseBody3 }),
            {error, {status, 404}};
        {error, Reason} ->  
            ReasonString = lists:flatten(io_lib:format("~p", [{error, Reason}])),
            ReasonString2 = re:replace(re:replace(ReasonString, "\n", "", [global,{return,list}]), "\s{2,}", " ", 
                                [global,{return,list}]),
            ResponseBody4 = [{node(), list_to_binary(ReasonString2)}],
            Req:respond({500, [{"Content-Type", "application/json"}], ResponseBody4 }),
            rabbit_log:warning("RabbitHub 500 Error during Delete of ~p~n Error: ~p~n", [Sub, Reason]), 
            {error, {status, 500}}
    end.                                

create_ha_consumers(Nodes, Subscription, LeaseSeconds, HAMode, MaxTps, Status) ->        
        {Results, BadNodes} = rpc:multicall(Nodes, rabbithub_subscription, create, [Subscription, LeaseSeconds, HAMode, MaxTps, Status]),
        %% create list of [{node1, result1}, {node2, result2},...]
        FullResults = lists:append(
            lists:zip(Nodes -- BadNodes, Results),
            [{BN, {badrpc, nodedown}} || BN <- BadNodes]
        ),
        %% restore original order
        RPCResults = [{N, Res} || N <- Nodes, {M, Res} <- FullResults, N == M],
        RPCResults.
        

deactivate_ha_consumers(Subscription) ->
        ExistingConsumers = find_existing_consumers(Subscription),
            case ExistingConsumers of 
                [] ->
                    [{node(), ok}];
                ConsumerList ->
                    Nodes = [element(3, element(2, C)) || C <- ConsumerList],           
                    {Results, BadNodes} = rpc:multicall(Nodes, rabbithub_subscription, delete_local_consumer, [Subscription]),
                    %% remove pid table entries for bad nodes
                    lists:foreach(fun(N) ->
                      remove_pid(N, Subscription) end, BadNodes),
                      
                    %% create list of [{node1, result1}, {node2, result2},...]
                    FullResults = lists:append(
                        lists:zip(Nodes -- BadNodes, Results),
                        [{BN, {badrpc, nodedown}} || BN <- BadNodes]
                    ),
                    %% restore original order
                    RPCResults = [{N, Res} || N <- Nodes, {M, Res} <- FullResults, N == M],
                    RPCResults   
           end.
            
remove_pid(N, Subscription) ->
    Consumer = #consumer{subscription = Subscription, node = N},
    {atomic, ok} =
        mnesia:transaction(fun () -> mnesia:delete({rabbithub_subscription_pid, Consumer}) end),
     ok.   


            
get_nodes(Mode) ->
    case Mode of
        all -> nodes();
        Num when is_integer(Num)-> pick_n_random_nodes(Num, nodes());
        _ -> []
    end.
is_valid_ha_mode(Mode) ->
    case Mode of
        all -> true;
        none -> true;
        Num when is_integer(Num) -> true;
        _Other -> false
    end.

pick_n_random_nodes(N, _) when N == 0 ->
    [];
	
pick_n_random_nodes(N, List) when N > 0 ->
    ListLen = length(List),
    case ListLen of
        0 -> [];
        _Num -> 
            NumNodes = case N > ListLen of
                        true ->  ListLen;
                        false -> N
                       end,
            Index = random:uniform(length(List)),
            Element = lists:nth(Index,List),
            Result = [Element] ++ pick_n_random_nodes(NumNodes-1, lists:delete(Element, List)),
            Result
    end.
            
%% GF: function to convert list of node responses to JSON	    
convert_response_body_to_json(Body) ->
    Data = {struct,  [{consumers, [
              [{node, element(1, B)},
               {status, convert_status(element(2,B))}]
	    || B <- Body]}]},
    Resp = mochijson2:encode(Data),
    Resp.
    
convert_status(Value) ->
    case Value of
        _ValueAtom when is_atom(Value) -> Value;
        _ValueBinary when is_binary(Value) -> Value;
        Other when is_tuple(Value) ->
            ValueString1 = lists:flatten(io_lib:format("~p", [Other])),
            ValueString2 = re:replace(re:replace(ValueString1, "\n", "", [global,{return,list}]), "\s{2,}", " ", [global,{return,list}]),
            list_to_binary(ValueString2)
    end.
                        

handle_hub_post(Req) ->
    Req:respond({200, [], "You posted!"}).
