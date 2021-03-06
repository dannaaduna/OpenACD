%%	The contents of this file are subject to the Common Public Attribution
%%	License Version 1.0 (the “License”); you may not use this file except
%%	in compliance with the License. You may obtain a copy of the License at
%%	http://opensource.org/licenses/cpal_1.0. The License is based on the
%%	Mozilla Public License Version 1.1 but Sections 14 and 15 have been
%%	added to cover use of software over a computer network and provide for
%%	limited attribution for the Original Developer. In addition, Exhibit A
%%	has been modified to be consistent with Exhibit B.
%%
%%	Software distributed under the License is distributed on an “AS IS”
%%	basis, WITHOUT WARRANTY OF ANY KIND, either express or implied. See the
%%	License for the specific language governing rights and limitations
%%	under the License.
%%
%%	The Original Code is OpenACD.
%%
%%	The Initial Developers of the Original Code is 
%%	Andrew Thompson and Micah Warren.
%%
%%	All portions of the code written by the Initial Developers are Copyright
%%	(c) 2008-2009 SpiceCSM.
%%	All Rights Reserved.
%%
%%	Contributor(s):
%%
%%	Andrew Thompson <andrew at hijacked dot us>
%%	Micah Warren <micahw at lordnull dot com>
%%

%% @doc A cdr dumper that makes a dets back repository of cdrs, one for each
%% day.  Also has some helper functions to load the data either to ets, or
%% back into mnesia.

-module(cdr_dets).
-author(micahw).

-behavior(gen_cdr_dumper).

-ifdef(TEST).
-include_lib("eunit/include/eunit.hrl").
-endif.

-include("log.hrl").
-include("call.hrl").
-include("agent.hrl").
-include_lib("stdlib/include/qlc.hrl").

%% API

%% gen_cdr_dumper callbacks
-export([
	init/1, 
	dump/2,
	commit/1,
	rollback/1,
	terminate/2, 
	code_change/3,
	load_to_mnesia/1,
	load_to_ets/1,
	load_to_ets/2,
	load_to_file/2]).

-record(state, {
	agent_dets_ref :: reference(),
	cdr_dets_ref :: reference(),
	log_dir = "/tmp/" :: string(),
	last_day :: {pos_integer(), pos_integer(), pos_integer()},
	agent_buffer = [] :: [#agent_state{}],
	cdr_buffer = [] :: [#cdr_rec{}]
}).

-type(state() :: #state{}).
-define(GEN_CDR_DUMPER, true).
-include("gen_spec.hrl").

%% @doc Takes all records in the passed dets file and loads them into mnesia.
%% This is useful if you want to migrate the records from the dets dumper to 
%% another dumper.  Best if used in a spawn, and when the dets dumper is not running.
-spec(load_to_mnesia/1 :: (File :: string()) -> 'ok').
load_to_mnesia(File) ->
	{ok, Detsref} = dets:open_file(File, [{keypos, 2}]),
	dets:safe_fixtable(Detsref, true),
	Objs = load_loop(Detsref),
	F = fun() ->
		lists:foreach(fun(O) -> mnesia:write(O) end, Objs)
	end,
	mnesia:transaction(F),
	dets:safe_fixtable(Detsref, false),
	dets:close(Detsref).

load_loop(Detsref) ->
	First = dets:first(Detsref),
	load_loop(First, Detsref, []).

load_loop('$end_of_table', _Detsref, Acc) ->
	lists:reverse(Acc);
load_loop(Key, Detsref, Acc) ->
	Obj = dets:lookup(Detsref, Key),
	load_loop(dets:next(Detsref, Key), Detsref, [Obj | Acc]).

%% @doc If loading to Mnesia is not wanted, but using tv is desired, loading to
%% ets can make a reasonable comprise.
-spec(load_to_ets/1 :: (File :: string()) -> any()).
load_to_ets(File) ->
	E = ets:new(ets_cdr, [{keypos, 2}]),
	load_to_ets(File, E).

%% @doc same as above, but you provide the 
-spec(load_to_ets/2 :: (File :: string(), Ets :: any()) -> any()).
load_to_ets(File, Ets) ->
	{ok, Dets} = dets:open_file(File, [{keypos, 2}]),
	dets:to_ets(Dets, Ets),
	Ets.

%% @doc Create a semi-human readable dump file.
-spec(load_to_file/2 :: (InFile :: string(), OutFile :: string()) -> pid()).
load_to_file(InFile, OutFile) ->
	spawn(fun() ->
		{ok, Out} = file:open(OutFile, [read, write]),
		{ok, Dets} = dets:open_file(InFile, [{keypos, 2}]),
		qlc:e(qlc:q([io:fwrite(Out, "~p.~n", [Row]) || Row <- dets:table(Dets)])),
		?INFO("File dump to ~s done.", [OutFile])
	end).

%%====================================================================
%% gen_cdr callbacks
%%====================================================================

init(Opts) ->
	Logdir = case proplists:get_value(logdir, Opts, dynamic) of
		dynamic ->
			case application:get_env('OpenACD', webdir_dynamic) of
				undefined ->
					"www/dynamic";
				{ok, WebDirDyn} ->
					WebDirDyn
			end;
		tmp ->
			"/tmp/";
		LogElse ->
			case lists:reverse(LogElse) of
				[$/ | _] ->
					LogElse;
				_ ->
					LogElse ++ "/"
			end
	end,
	{AdetsFile, CdetsFile} = make_file_names(Logdir),
	Adets = dets:open_file(agent_dets_ref, [{file, AdetsFile}, {keypos, 2}]),
	Cdets = dets:open_file(cdr_dets_ref, [{file, CdetsFile}, {keypos, 2}]),
	{Today, _} = calendar:local_time(),
	State = #state{
		agent_dets_ref = Adets,
		cdr_dets_ref = Cdets,
		log_dir = Logdir,
		last_day = Today
	},
	?INFO("cdr_dets started", []),
    {ok, State}.

terminate(Reason, State) ->
	?INFO("cdr_dets terminating due to ~p", [Reason]),
	dets:close(State#state.agent_dets_ref),
	dets:close(State#state.cdr_dets_ref),
    ok.

code_change(_OldVsn, State, _Extra) ->
    {ok, State}.

dump(Agentstate, #state{agent_buffer = Abuff} = State) when is_record(Agentstate, agent_state) ->
	Newbuff = [Agentstate | Abuff],
	{ok, State#state{agent_buffer = Newbuff}};
dump(CDR, #state{cdr_buffer = Cbuff} = State) when is_record(CDR, cdr_rec) ->
	Newbuff = [CDR | Cbuff],
	{ok, State#state{cdr_buffer = Newbuff}}.

commit(#state{last_day = Lastday} = State) ->
	{Newday, Adets, Cdets} = case calendar:local_time() of
		{Lastday, _} ->
			{Lastday, State#state.agent_dets_ref, State#state.cdr_dets_ref};
		{ANewday, _} ->
			{NewAdetsF, NewCdetsF} = make_file_names(State#state.log_dir),
			dets:close(agent_dets_ref),
			dets:close(cdr_dets_ref),
			NewAdets = dets:open_file(agent_dets_ref, [{file, NewAdetsF},{keypos, 2}]),
			NewCdets = dets:open_file(cdr_dets_ref, [{file, NewCdetsF},{keypos, 2}]),
			{ANewday, NewAdets, NewCdets}
	end,
	dets:insert(agent_dets_ref, State#state.agent_buffer),
	dets:insert(cdr_dets_ref, State#state.cdr_buffer),
	{ok, State#state{last_day = Newday, agent_dets_ref = Adets, cdr_dets_ref = Cdets, agent_buffer = [], cdr_buffer = []}}.

rollback(State) ->
	{ok, State#state{agent_buffer = [], cdr_buffer = []}}.

%%--------------------------------------------------------------------
%%% Internal functions
%%--------------------------------------------------------------------

make_file_names(Logdir) ->
	{{Year, Month, Day}, _} = calendar:local_time(),
	Append = lists:append([
		"-",
		integer_to_list(Year), 
		"-",
		integer_to_list(Month), 
		"-",
		integer_to_list(Day),
		".dets"
	]),
	AdetsFile = lists:append([Logdir, "agent_state", Append]), 
	CdetsFile = lists:append([Logdir, "cdr", Append]),
	{AdetsFile, CdetsFile}.
