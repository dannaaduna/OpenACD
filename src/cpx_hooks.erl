%% @doc Manager for plugins to OpenACD.  Sometimes it is useful for OpenACD
%% to be able to get information from other sources, or to allow other
%% sources to provide some information when a particular event occurs.
%% This module allows callback functions to be set when certain events
%% occur.  See the documentation of other modules to see what hooks they
%% trigger, what arguments they send, and the mode they use.  
%%
%% Plugins may also trigger hooks, though it is ill-advised to trigger 
%% system hooks, or hooks defined by other plugins.
%%
%% When a hook is triggered, the arguments for a callback are appended to
%% the arugments passed in when the hook was triggered.  Thus, the arity of
%% the callback function must be equal to the length of the trigger's
%% arguments plus the length of the hook's arguments.
%%
%% Hooks are called in order of priority going from lowest number to 
%% highest.
%%
%% A hook can be triggered in one oftwo modes:  first or all.  If a hook is
%% triggered in 'first' mode, the first callback to return `{ok, Term}' 
%% stops other hooks from being called, and `{ok, Term}' is returned.  If
%% no callback returns `{ok, Term}', `{error, not_handled}' is returned.
%% In 'all' mode, each callback that returns `{ok, Term}' is collected in
%% a list, and `{ok, [Term]}' is returned.
%%
%% If a callback errors, it is removed from the list no matter which mode
%% the hook was triggered in.
-module(cpx_hooks).
-behavior(gen_server).

-ifdef(TEST).
-include_lib("eunit/include/eunit.hrl").
-endif.

-include("log.hrl").
-include_lib("stdlib/include/qlc.hrl").

% gen_server
-export([init/1, handle_call/3, handle_cast/2, handle_info/2, terminate/2,
	code_change/3]).
% api
-export([start_link/0, set_hook/3, set_hook/6, drop_hook/1, trigger_hooks/2,
	trigger_hooks/3]).

%% =================================================================
%% API
%% =================================================================

%% @doc Creates the hooks ets table.
start_link() ->
	gen_server:start_link({local, ?MODULE}, ?MODULE, {}, []).

%% @doc Add a new hook to the trigger event `Hook'.
-spec(set_hook/3 :: (Id :: any(), Hook :: atom(), {M :: atom(), F :: atom(),
	A :: [any()]}) -> 'true').
set_hook(Id, Hook, {M, F, A}) ->
	set_hook(Id, Hook, M, F, A, 100).

%% @doc Add a new hook to the trigger event `Hook'.
-spec(set_hook/6 :: (Id :: any(), Hook :: atom(), M :: atom(), F :: atom(),
	A :: [any()], Priority :: integer()) -> 'true').
set_hook(Id, Hook, M, F, A, Priority) when is_list(A) ->
	ets:insert(cpx_hooks, {Id, Hook, M, F, A, Priority}).

%% @doc Remove a hook from being triggered.
-spec(drop_hook/1 :: (Id :: any()) -> 'true').
drop_hook(Id) ->
	ets:delete(cpx_hooks, Id).
	%gen_server:cast(?MODULE, {drop_hook, Id}).

%% @doc Begin calling the callbacks for trigger event `Hook' in the `first'
%% mode.
-spec(trigger_hooks/2 :: (Hook :: atom(), Args :: [any()]) -> {'ok', any()}
	| {'error', 'not_handled'}).
trigger_hooks(Hook, Args) ->
	trigger_hooks(Hook, Args, first).

%% @doc Begin calling the callbacks for trigger event `Hook'.
-spec(trigger_hooks/3 :: (Hook :: atom(), Args :: [any()], StopWhen ::
	'first' | 'all') -> {'ok', any()} | {'error', 'not_handled'}).
trigger_hooks(Hook, Args, StopWhen) ->
	Hooks = qlc:e(qlc:q([{P, M, F, A, Id} || 
		{Id, EHook, M, F, A, P} <- ets:table(cpx_hooks),
		EHook == Hook
	])),
	Hooks0 = lists:sort(Hooks),
	case StopWhen of
		first -> run_hooks(Hooks0, Args, first);
		all -> run_hooks(Hooks0, Args, [])
	end.

%% @doc Stop the hooks module, thus removing the ets table that backs the
%% system.
stop() ->
	gen_server:call(?MODULE, stop).

%% =================================================================
%% gen_server
%% =================================================================

%% -----------------------------------------------------------------
%% init
%% -----------------------------------------------------------------

%% @private
init(_) ->
	Ets = ets:new(cpx_hooks, [named_table, public]),
	{ok, Ets}.

%% -----------------------------------------------------------------
%% handle_call
%% -----------------------------------------------------------------

%% @private
handle_call(stop, _, Ets) ->
	{stop, normal, ok, Ets};

%% @private
handle_call(_, _, Ets) ->
	{reply, invalid, Ets}.


%% -----------------------------------------------------------------
%% handle_cast
%% -----------------------------------------------------------------

%% @private
handle_cast({set_hook, Id, Hook, M, F, A, Priority} = H, Ets) ->
	?DEBUG("Setting ~p", [H]),
	ets:insert(Ets, {Id, Hook, M, F, A, Priority}),
	{noreply, Ets};

%% @private
handle_cast({drop_hook, Id}, Ets) ->
	ets:delete(Ets, Id),
	{noreply, Ets}.


%% -----------------------------------------------------------------
%% handle_info
%% -----------------------------------------------------------------

%% @private
handle_info(_, Ets) ->
	{noreply, Ets}.


%% -----------------------------------------------------------------
%% terminate
%% -----------------------------------------------------------------

%% @private
terminate(_Reason, Ets) ->
	Ets.

%% -----------------------------------------------------------------
%% code_change
%% -----------------------------------------------------------------

%% @private
code_change(_OldVsn, Ets, _Extra) ->
	{ok, Ets}.

%% =================================================================
%% internal
%% =================================================================

run_hooks([], _Args, first) ->
	{error, unhandled};

run_hooks([], _Args, Out) ->
	{ok, Out};

run_hooks([{_P, M, F, A, Id} | Tail], Args, StopWhen) ->
	Args0 = lists:append(Args, A),
	try {apply(M, F, Args0), StopWhen} of
		{{ok, Val}, first} ->
			?DEBUG("hook ~p supplied value", [Id]),
			{ok, Val};
		{{ok, Val}, Acc} ->
			run_hooks(Tail, Args, [Val | Acc]);
		{Else, _} ->
			?DEBUG("Hook ~p gave back a weird value:  ~p", [Id, Else]),
			run_hooks(Tail, Args, StopWhen)
	catch
		What:Why ->
			?NOTICE("Hook ~p failed with ~p:~p", [Id, What, Why]),
			drop_hook(Id),
			run_hooks(Tail, Args, StopWhen)
	end.


%% =================================================================
%% TEST
%% =================================================================

-ifdef(TEST).
-compile([export_all]).

hook_test_() ->
	{foreach, fun() ->
		meck:new(hook_tester),
		{ok, P} = start_link(),
		P
	end,
	fun(_P) ->
		meck:unload(hook_tester),
		stop(),
		timer:sleep(100)
	end, [
		fun(_P) ->
			{"no hooks", fun() ->
				Out = trigger_hooks(hook, []),
				?assertEqual({error, unhandled}, Out)
			end}
		end,

		fun(_) ->
			{"Hook stops another from happening", fun() ->
					meck:expect(hook_tester, good_skip, fun() ->
						ok
					end),
					meck:expect(hook_tester, good_return, fun() ->
						{ok, ok}
					end),
					meck:expect(hook_tester, donotwant, fun() ->
						erlang:error(donotwant_hit)
					end),
					set_hook(skipped, hook, hook_tester, good_skip, [], 1),
					set_hook(good, hook, hook_tester, good_return, [], 2),
					set_hook(error, hook, hook_tester, donotwant, [], 3),
					%timer:sleep(10),
					Out = trigger_hooks(hook, []),
					?assertEqual({ok, ok}, Out)
			end}
		end,

		fun(_) ->
			{"Bad hook removed", fun() ->
				meck:expect(hook_tester, donotwant, fun() ->
					erlang:error(donotwant_hit)
				end),
				set_hook(1, hook, {hook_tester, donotwant_hit, []}),
				trigger_hooks(hook, []),
				Out = qlc:e(qlc:q([X || X <- ets:table(cpx_hooks)])),
				?assertEqual([], Out)
			end}
		end,

		fun(_) ->
			{"hook fold works", fun() ->
				meck:expect(hook_tester, callback, fun(Action) ->
					case Action of
						$i -> {ok, $i};
						$h -> {ok, $h};
						{error, Err} -> erlang:error(Err);
						Else -> Else
					end
				end),
				set_hook(first, hook, hook_tester, callback, [$i], 1),
				set_hook(second, hook, hook_tester, callback, [{error, donotwant}], 2),
				set_hook(third, hook, hook_tester, callback, [jelly], 3),
				set_hook(forth, hook, hook_tester, callback, [$h], 4),
				Out = trigger_hooks(hook, [], all),
				?assertEqual({ok, "hi"}, Out)
			end}
		end

	]}.


-endif.
