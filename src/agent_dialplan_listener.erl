%% "The contents of this file are subject to the Mozilla Public License
%% Version 1.1 (the "License"); you may not use this file except in
%% compliance with the License. You may obtain a copy of the License at
%% http://www.mozilla.org/MPL/
%%
%% Software distributed under the License is distributed on an "AS IS"
%% basis, WITHOUT WARRANTY OF ANY KIND, either express or implied. See the
%% License for the specific language governing rights and limitations
%% under the License.
%%
%%	The Original Code is OpenACD.
%%
%%	The Initial Developers of the Original Code is 
%%	Andrew Thompson.
%%
%%	All portions of the code written by the Initial Developers are Copyright
%%	(c) 2008-2010 Andrew Thompson.
%%	All Rights Reserved.
%%
%%	Contributor(s):
%%
%%	Andrew Thompson <andrew at hijacked dot us>

%% @doc Listener for agent events from the dialplan -- dialplan agents can be started from
%% here and then subsequently control them.

-module(agent_dialplan_listener).

-behaviour(gen_server).

-include("log.hrl").
-include("call.hrl").
%-include("queue.hrl").
-include("agent.hrl").

-ifdef(TEST).
-include_lib("eunit/include/eunit.hrl").
-endif.

-record(state, {
	registry = dict:new() :: dict(),
	start_opts = [] :: start_opts()
}).

-type(state() :: #state{}).
-define(GEN_SERVER, true).
-include("gen_spec.hrl").

%% API
-export([start/0, start_link/0, start/1, start_link/1, stop/0]).

%% gen_server callbacks
-export([init/1, handle_call/3, handle_cast/2, handle_info/2,
	 terminate/2, code_change/3]).

-type(unavailable_timeout_opt() :: {'unavailable_timeout', integer()}).
-type(start_opt() :: unavailable_timeout_opt()).
-type(start_opts() :: [start_opt()]).

-spec(start/0 :: () -> {'ok', pid()}).
start() ->
	start([]).

-spec(start/1 :: (Options :: start_opts()) -> {'ok', pid()}).
start(Options) ->
	gen_server:start({local, ?MODULE}, ?MODULE, Options, []).

-spec(start_link/0 :: () -> {'ok', pid()}).
start_link() ->
	start_link([]).

-spec(start_link/1 :: (Options :: start_opts()) -> {'ok', pid()}).
start_link(Options) ->
	gen_server:start_link({local, ?MODULE}, ?MODULE, Options, []).

-spec(stop/0 :: () -> 'ok').
stop() ->
	gen_server:call(?MODULE, stop).

init(Options) ->
	process_flag(trap_exit, true),
	{ok, #state{start_opts = Options}}.

handle_call(Request, From, State) ->
	?DEBUG("Call from ~p:  ~p", [From, Request]),
	{reply, {unknown_call, Request}, State}.

handle_cast(Msg, State) ->
	?DEBUG("Cast ~p", [Msg]),
	{noreply, State}.

handle_info({freeswitch_sendmsg, "agent_login " ++ Parameters}, State) ->

	{Username, EndpointRes} = case util:string_split(Parameters, " ") of
		[U] ->
			{U, construct_endpoint(sip_registration, U)};
		[U, EndpointType] ->
			{U, construct_endpoint(EndpointType, U)};
		[U, EndpointType, EndpointData] ->
			{U, construct_endpoint(EndpointType, EndpointData)};
		_ ->
			{undefined, {error, invalid_param_count}}
	end,

	case EndpointRes of
		{error, Err} ->
			?WARNING("error ~p for agent_login parameters ~p", [Err, Parameters]),
			{noreply, State};
		{ok, Endpoint} ->
			case dict:find(Username, State#state.registry) of
				error ->
					case agent_auth:get_agent(Username) of
						{atomic, []} ->
							?INFO("no such agent ~p", [Username]),
							{noreply, State};
						{atomic, [_A, _B | _]} ->
							?WARNING("more than one agent found for username ~p, login failed", [Username]),
							{noreply, State};
						{atomic, [_AgentAuth]} when Endpoint == error ->
							?WARNING("~p tried to login with invalid endpoint parameters ~p", [Parameters]);
						{atomic, [AgentAuth]} ->
							Agent = #agent{
								id = AgentAuth#agent_auth.id,
								login = AgentAuth#agent_auth.login,
								skills = lists:umerge(lists:sort(AgentAuth#agent_auth.skills), lists:sort(['_agent', '_node'])),
								profile = AgentAuth#agent_auth.profile,
								security_level = AgentAuth#agent_auth.securitylevel
							},
							case agent_dialplan_connection:start(Agent, proplists:get_value(unavailable_timeout, State#state.start_opts)) of
								{ok, Pid} ->
									?INFO("~s logged in with endpoint ~p", [Username, Endpoint]),
									gen_server:call(Pid, {set_endpoint, Endpoint}),
									link(Pid),
									{noreply, State#state{registry = dict:store(Username, Pid, State#state.registry)}};
								ignore ->
									?WARNING("Ignore message trying to start connection for ~p", [Username]),
									{noreply, State};
								{error, Error} ->
									?ERROR("Error ~p trying to start connection for ~p", [Error, Username]),
									{noreply, State}
							end
					end;
				{ok, Pid} ->
					?NOTICE("~p is already logged in at ~p", [Username, Pid]),
					{noreply, State}
			end
	end;
handle_info({freeswitch_sendmsg, "agent_logoff " ++ Username}, State) ->
	case dict:find(Username, State#state.registry) of
		{ok, Pid} ->
			?DEBUG("requesting ~p logoff", [Username]),
			catch agent_dialplan_connection:logout(Pid),
			% wait for the EXIT message to cleanup
			{noreply, State};
		error ->
			?NOTICE("~p is not logged in", [Username]),
			{noreply, State}
	end;
handle_info({freeswitch_sendmsg, "agent_release " ++ Username}, State) ->
	case dict:find(Username, State#state.registry) of
		{ok, Pid} ->
			?DEBUG("requesting ~p go released", [Username]),
			catch agent_dialplan_connection:go_released(Pid),
			{noreply, State};
		error ->
			?NOTICE("~p is not logged in", [Username]),
			{noreply, State}
	end;
handle_info({freeswitch_sendmsg, "agent_available " ++ Username}, State) ->
	case dict:find(Username, State#state.registry) of
		{ok, Pid} ->
			?DEBUG("requesting ~p go available", [Username]),
			catch agent_dialplan_connection:go_available(Pid),
			{noreply, State};
		error ->
			?NOTICE("~p is not logged in", [Username]),
			{noreply, State}
	end;
handle_info({'EXIT', Pid, Reason}, State) ->
	?DEBUG("Doing a cleanup for pid ~w which died due to ~p", [Pid, Reason]),
	List = [ {B, A} || {A, B} <- dict:to_list(State#state.registry) ],
	case proplists:get_value(Pid, List) of
		undefined ->
			?INFO("unable to find entry for ~p", [Pid]),
			{noreply, State};
		Value ->
			?INFO("removing connection for ~p at ~p", [Value, Pid]),
			{noreply, State#state{registry = dict:erase(Value, State#state.registry)}}
		end;
handle_info(Info, State) ->
	?DEBUG("Info:  ~p", [Info]),
	{noreply, State}.

terminate(Reason, _State) when Reason == normal; Reason == shutdown ->
	?NOTICE("Graceful termination:  ~p", [Reason]),
	ok;
terminate(Reason, _State) ->
	?NOTICE("Terminating dirty:  ~p", [Reason]),
	ok.

code_change(_OldVsn, State, _Extra) ->
	{ok, State}.

%% TODO - this should be a common function
construct_endpoint(Type, Data) when is_list(Type) ->
	case catch list_to_existing_atom(Type) of
		{'EXIT', {badarg, _}} ->
			{error, invalid_type};
		Atm ->
			construct_endpoint(Atm, Data)
	end;
construct_endpoint(Type, Data) ->
	Types = [sip, sip_registration, h323, iax2, pstn],
	case lists:member(Type, Types) of
		true ->
			{ok, {freeswitch_media, [{type, Type}, {data, Data}]}};
		false ->
			{error, invalid_type}
	end.