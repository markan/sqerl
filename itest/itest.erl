%% Copyright 2012 Opscode, Inc. All Rights Reserved.
%%
%% This file is provided to you under the Apache License,
%% Version 2.0 (the "License"); you may not use this file
%% except in compliance with the License.  You may obtain
%% a copy of the License at
%%
%%   http://www.apache.org/licenses/LICENSE-2.0
%%
%% Unless required by applicable law or agreed to in writing,
%% software distributed under the License is distributed on an
%% "AS IS" BASIS, WITHOUT WARRANTIES OR CONDITIONS OF ANY
%% KIND, either express or implied.  See the License for the
%% specific language governing permissions and limitations
%% under the License.
%%

-module(itest).

-exports([setup_env/0, basic_test_/0,
          statements/1]).

-include_lib("eunit/include/eunit.hrl").
-include("sqerl.hrl").

-record(user, {id, first_name, last_name, high_score, active}).

-define(GET_ARG(Name, Args), proplists:get_value(Name, Args)).
-define(NAMES, [["Kevin", "Smith", 666, <<"2011-10-01 16:47:46">>, true],
                ["Mark", "Anderson", 42, <<"2011-10-02 16:47:46">>, true],
                ["Chris", "Maier", 0, <<"2011-10-03 16:47:46">>, true],
                ["Elvis", "Presley", 16, <<"2011-10-04 16:47:46">>, false]]).
-define(MAX_POOL_COUNT, 3).

-compile([export_all]).

get_db_type() ->
    {ok, [[Type]]} = init:get_argument(db_type),
    list_to_atom(Type).

read_db_config() ->
    Type = get_db_type(),
    Path = filename:join([filename:dirname(code:which(?MODULE)), atom_to_list(Type) ++ ".config"]),
    {ok, Config} = file:consult(Path),
    Config.

setup_env() ->
    Type = get_db_type(),
    Info = read_db_config(),
    ok = application:set_env(sqerl, db_type, Type),
    ok = application:set_env(sqerl, db_host, ?GET_ARG(host, Info)),
    ok = application:set_env(sqerl, db_port, ?GET_ARG(port, Info)),
    ok = application:set_env(sqerl, db_user, "itest"),
    ok = application:set_env(sqerl, db_pass, "itest"),
    ok = application:set_env(sqerl, db_name, ?GET_ARG(db, Info)),
    ok = application:set_env(sqerl, idle_check, 10000),
    %% we could also call it like this:
    %% {prepared_statements, statements(Type)},
    %% {prepared_statements, "itest/statements_pgsql.conf"},
    ok = application:set_env(sqerl, prepared_statements, {?MODULE, statements, [Type]}),
    ColumnTransforms = case Type of
                           pgsql ->
                               [{<<"created">>,
                                 fun sqerl_transformers:convert_YMDHMS_tuple_to_datetime/1}];
                           mysql ->
                               [{<<"active">>,
                                 fun sqerl_transformers:convert_integer_to_boolean/1}]
                       end,
    ok = application:set_env(sqerl, column_transforms, ColumnTransforms),
    PoolConfig = [{name, "sqerl"},
                  {max_count, ?MAX_POOL_COUNT},
                  {init_count, 1},
                  {start_mfa, {sqerl_client, start_link, []}}],
    ok = application:set_env(pooler, pools, [PoolConfig]),
    application:start(crypto),
    application:start(emysql),
    application:start(public_key),
    application:start(ssl),
    application:start(epgsql).

statements(mysql) ->
    {ok, Statements} = file:consult("itest/statements_mysql.conf"),
    Statements;
statements(pgsql) ->
    {ok, Statements} = file:consult("itest/statements_pgsql.conf"),
    Statements.

basic_test_() ->
    setup_env(),
    Status = application:start(sqerl),
    %% sqerl should start or already be running for each test
    ?assert(lists:member(Status, [ok, {error, {already_started, sqerl}}])),
    {foreach,
     fun() -> error_logger:tty(true) end,
     fun(_) -> error_logger:tty(true) end,
     [
      {<<"Connection pool overflow">>,
       fun pool_overflow/0},
      {<<"Insert operations">>,
       fun insert_data/0},
      {<<"Select operations">>,
       fun select_data/0},
      {<<"Select w/record xform operations">>,
       fun select_data_as_record/0},
      {<<"Ensure a select that returns the number zero doesn't come back as 'none'">>,
       fun select_first_number_zero/0},
      {<<"Update blob type">>,
       fun update_datablob/0},
      {<<"Select blob type">>,
       fun select_datablob/0},
      {<<"Select boolean">>,
       fun select_boolean/0},

      {<<"Update timestamp type">>,
       fun update_created/0},
      {<<"Select timestamp type">>,
       fun select_created_by_lname/0},
      {<<"Select timestamp type">>,
       fun select_lname_by_created/0},

      {<<"Tolerates bounced server">>,
       {timeout, 10,
        fun bounced_server/0}},

      {<<"Delete operation">>,
       fun delete_data/0},
      {"Resultset-returning Stored Procedure",
       fun() ->
               case get_db_type() of
                   mysql ->
                       %% It won't actually return anything; this is just to
                       %% make sure that we're properly handling the insanity
                       %% of MySQL returning multiple results from a stored
                       %% procedure call.
                       %%
                       %% Basically, the fact that it doesn't crash is test
                       %% enough :)
                       {ok, Actual} = sqerl:select(test_the_sp, []),
                       ?assertEqual(none, Actual);
                   Type ->
                       ?debugFmt("Skipping stored procedure test for non-MySQL database ~p~n", [Type])
               end
       end},
      {foreach,
       fun() ->
               %% Don't want to have the error message muddy up the test output
               error_logger:tty(false) end,
       fun(_) -> error_logger:tty(true) end,
       [{"Does NOT handle SPs that return more than one result packet",
         fun() ->
                 case get_db_type() of
                     mysql ->
                         ?assertException(exit,
                                          {{{case_clause, [_Result1,_Result2,_OKPacket]}, _}, _},
                                          sqerl:select(test_the_multi_sp, []));
                     Type ->
                         ?debugFmt("Skipping stored procedure test for non-MySQL database ~p~n", [Type])
                 end
         end}]
      }
     ]}.

kill_pool(1) ->
    pooler:take_member();
kill_pool(X) ->
    pooler:take_member(),
    kill_pool(X - 1).

pool_overflow() ->
    kill_pool(?MAX_POOL_COUNT),
    % Doesn't matter what we do from here; we're just testing operations with
    % a depleted pool
    Expected = {error, no_connections},
    Results = sqerl:select(find_user_by_lname, ["Smith"], ?FIRST(user)),
    ?assertEqual(Expected, Results).

insert_data() ->
    Expected = lists:duplicate(4, {ok, 1}),
    ?assertMatch(Expected, [sqerl:statement(new_user, Name) || Name <- ?NAMES]).

select_data() ->
    {ok, User} = sqerl:select(find_user_by_lname, ["Smith"], first),
    ?assertMatch(<<"Kevin">>, proplists:get_value(<<"first_name">>, User)),
    ?assertMatch(<<"Smith">>, proplists:get_value(<<"last_name">>, User)),
    ?assertEqual(666, proplists:get_value(<<"high_score">>, User)),
    ?assertEqual(true, proplists:get_value(<<"active">>, User)),
    ?assert(is_integer(proplists:get_value(<<"id">>, User))).

select_data_as_record() ->
    {ok, User} = sqerl:select(find_user_by_lname, ["Smith"], ?FIRST(user)),
    ?assertMatch(<<"Kevin">>, User#user.first_name),
    ?assertMatch(<<"Smith">>, User#user.last_name),
    ?assertEqual(666, User#user.high_score),
    ?assertEqual(true, User#user.active),
    ?assert(is_integer(User#user.id)).

select_first_number_zero() ->
    Expected = [{ok, 666}, {ok, 42}, {ok, 0}, {ok, 16} ],
    Returned =  [sqerl:select(find_score_by_lname, [LName], first_as_scalar, [high_score]) ||
                    [_, LName, _, _, _] <- ?NAMES],
    ?assertMatch(Expected, Returned).

delete_data() ->
    Expected = lists:duplicate(4, {ok, 1}),
    ?assertMatch(Expected, [sqerl:statement(delete_user_by_lname, [LName]) ||
                               [_, LName, _, _, _] <- ?NAMES]).

bounced_server() ->
    case get_db_type() of
        mysql ->
            os:cmd("mysql.server stop"),
            os:cmd("mysql.server start"),
            {ok, Result} = sqerl:select(find_user_by_lname, ["Smith"], first),
            ?assertMatch(<<"Smith">>, proplists:get_value(<<"last_name">>, Result));
        Type ->
            ?debugFmt("Skipping bounced server test for ~p~n", [Type])
    end.

update_datablob() ->
    ?assertMatch({ok, 1},
                 sqerl:statement(update_datablob_by_lname,
                                 [<<"foobar">>, "Smith"] )).

select_datablob() ->
    {ok, User} = sqerl:select(find_datablob_by_lname, ["Smith"], first_as_scalar, [datablob]),
    ?assertMatch(<<"foobar">>, User).

select_boolean() ->
    {ok, User} = sqerl:select(find_user_by_lname, ["Smith"], first),
    ?assertEqual(true, proplists:get_value(<<"active">>, User)),

    {ok, User1} = sqerl:select(find_user_by_lname, ["Presley"], first),
    ?assertEqual(false, proplists:get_value(<<"active">>, User1)).


%%%
%%% Tests for timestamp behavior....
%%%
update_created() ->
    ?assertMatch({ok, 1},
                 sqerl:statement(update_created_by_lname,
                     [{datetime, {{2011, 11, 1}, {16, 47, 46}}},
                      "Smith"])),
    ?assertMatch({ok, 1},
                 sqerl:statement(update_created_by_lname,
                     [{{2011, 11, 2}, {16, 47, 46}}, "Anderson"])),
    ?assertMatch({ok, 1},
                 sqerl:statement(update_created_by_lname,
                     [<<"2011-11-03 16:47:46">>, "Maier"])),

    {ok, User1} = sqerl:select(find_created_by_lname, ["Smith"], first_as_scalar, [created]),
    ?assertMatch({datetime, {{2011, 11, 01}, {16, 47, 46}}}, User1),
    {ok, User2} = sqerl:select(find_created_by_lname, ["Anderson"], first_as_scalar, [created]),
    ?assertMatch({datetime, {{2011, 11, 02}, {16, 47, 46}}}, User2),
    {ok, User3} = sqerl:select(find_created_by_lname, ["Maier"], first_as_scalar, [created]),
    ?assertMatch({datetime, {{2011, 11, 03}, {16, 47, 46}}}, User3).

select_created_by_lname() ->
    {ok, User1} = sqerl:select(find_created_by_lname, ["Presley"], first_as_scalar, [created]),
    ?assertMatch({datetime, {{2011, 10, 04}, {16, 47, 46}}}, User1).
select_lname_by_created() ->
    {ok, User1} = sqerl:select(find_lname_by_created, [{datetime, {{2011, 10, 04}, {16, 47, 46}}}], first_as_scalar, [last_name]),
    ?assertMatch(<<"Presley">>, User1).
