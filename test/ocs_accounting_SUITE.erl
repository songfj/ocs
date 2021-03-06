%%% ocs_accounting_SUITE.erl
%%% vim: ts=3
%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%
%%% @copyright 2016 - 2017 SigScale Global Inc.
%%% @end
%%% Licensed under the Apache License, Version 2.0 (the "License");
%%% you may not use this file except in compliance with the License.
%%% You may obtain a copy of the License at
%%%
%%%     http://www.apache.org/licenses/LICENSE-2.0
%%%
%%% Unless required by applicable law or agreed to in writing, software
%%% distributed under the License is distributed on an "AS IS" BASIS,
%%% WITHOUT WARRANTIES OR CONDITIONS OF ANY KIND, either express or implied.
%%% See the License for the specific language governing permissions and
%%% limitations under the License.
%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%
%%%  @doc Test suite for accounting of the {@link //ocs. ocs} application.
%%%
-module(ocs_accounting_SUITE).
-copyright('Copyright (c) 2016 - 2017 SigScale Global Inc.').

%% common_test required callbacks
-export([suite/0, sequences/0, all/0]).
-export([init_per_suite/1, end_per_suite/1]).
-export([init_per_testcase/2, end_per_testcase/2]).

%% Note: This directive should only be used in test suites.
-compile(export_all).

-include_lib("radius/include/radius.hrl").
-include("ocs.hrl").
-include("ocs_eap_codec.hrl").
-include_lib("common_test/include/ct.hrl").
-include_lib("diameter/include/diameter.hrl").
-include_lib("diameter/include/diameter_gen_base_rfc6733.hrl").
-include_lib("../include/diameter_gen_nas_application_rfc7155.hrl").
-include_lib("../include/diameter_gen_cc_application_rfc4006.hrl").
-include_lib("../include/diameter_gen_3gpp_ro_application.hrl").
-include_lib("../include/diameter_gen_3gpp.hrl").
-include_lib("../include/diameter_gen_ietf.hrl").

-define(SVC_AUTH, diameter_client_auth_service).
-define(SVC_ACCT, diameter_client_acct_service).
-define(BASE_APPLICATION_ID, 0).
-define(NAS_APPLICATION_ID, 1).
-define(RO_APPLICATION_ID, 4).
-define(EPOCH_OFFSET, 2208988800).
%% support deprecated_time_unit()
-define(MILLISECOND, milli_seconds).
%-define(MILLISECOND, millisecond).

%%---------------------------------------------------------------------
%%  Test server callback functions
%%---------------------------------------------------------------------

-spec suite() -> DefaultData :: [tuple()].
%% Require variables and set default values for the suite.
%%
suite() ->
	[{userdata, [{doc, "Test suite for accounting in OCS"}]},
	{require, radius_shared_secret}, {default_config, radius_shared_secret, "abc345"},
	{timetrap, {seconds, 8}}].

-spec init_per_suite(Config :: [tuple()]) -> Config :: [tuple()].
%% Initialization before the whole suite.
%%
init_per_suite(Config) ->
	ok = ocs_test_lib:initialize_db(),
	ok = ocs_test_lib:start(),
	{ok, ProdID} = ocs_test_lib:add_offer(),
	{ok, EnvList} = application:get_env(ocs, diameter),
	{acct, [{Address, Port, Options } | _]} = lists:keyfind(acct, 1, EnvList),
	true = diameter:subscribe(?SVC_ACCT),
	ok = diameter:start_service(?SVC_ACCT, client_acct_service_opts(Options)),
	{ok, _Ref2} = connect(?SVC_ACCT, Address, Port, diameter_tcp),
	receive
		#diameter_event{service = ?SVC_ACCT, info = start} ->
			[{product_id, ProdID}, {diameter_auth_client, Address} | Config];
		_ ->
			{skip, diameter_client_acct_service_not_started}
	end.

-spec end_per_suite(Config :: [tuple()]) -> any().
%% Cleanup after the whole suite.
%%
end_per_suite(Config) ->
	ok = diameter:stop_service(?SVC_AUTH),
	ok = diameter:stop_service(?SVC_ACCT),
	ok = ocs_test_lib:stop(),
	ok = ocs:delete_service("25252525"),
	Config.

-spec init_per_testcase(TestCase :: atom(), Config :: [tuple()]) -> Config :: [tuple()].
%% Initialization before each test case.
%%
init_per_testcase(TestCase, Config) when
		TestCase == diameter_accounting; TestCase == diameter_disconnect_session ->
	{ok, EnvList} = application:get_env(ocs, diameter),
	{acct, [{Address, _Port, _Options } | _]} = lists:keyfind(acct, 1, EnvList),
	{ok, _} = ocs:add_client(Address, undefined, diameter, undefined, true),
	Config;
init_per_testcase(_TestCase, Config) ->
	NasID = erlang:ref_to_list(make_ref()),
	Port = ocs_test_lib:port(),
	SharedSecret = ct:get_config(radius_shared_secret),
	{ok, _} = ocs:add_client({127, 0, 0, 1}, Port, radius, SharedSecret, true),
	Config1 = lists:keystore(nas_id, 1, Config, {nas_id, NasID}),
	lists:keystore(radius_disc_port, 1, Config1, {radius_disc_port, Port}).

-spec end_per_testcase(TestCase :: atom(), Config :: [tuple()]) -> any().
%% Cleanup after each test case.
%%
end_per_testcase(TestCase, Config) when
		TestCase == diameter_accounting; TestCase == diameter_disconnect_session ->
	Client = ?config(diameter_auth_client, Config),
	ok = ocs:delete_client(Client);
end_per_testcase(_TestCase, _Config) ->
	ocs:delete_client({127, 0, 0, 1}).

-spec sequences() -> Sequences :: [{SeqName :: atom(), Testcases :: [atom()]}].
%% Group test cases into a test sequence.
%%
sequences() ->
	[].

-spec all() -> TestCases :: [Case :: atom()].
%% Returns a list of all test cases in this test suite.
%%
all() ->
	[radius_accounting, radius_disconnect_session,
	radius_multisession_disallowed, radius_multisession,
	diameter_accounting, diameter_disconnect_session,
	diameter_sms].

%%---------------------------------------------------------------------
%%  Test cases
%%---------------------------------------------------------------------

radius_accounting() ->
	[{userdata, [{doc, "Initiate and terminate a RADIUS accounting session"}]}].

radius_accounting(Config) ->
	RadID1 = 1,
	NasID = ?config(nas_id, Config),
	AcctSessionID = ocs:generate_identity(),
	{ok, [{auth, AuthInstance}, {acct, AcctInstance}]} = application:get_env(ocs, radius),
	[{AuthAddress, AuthPort, _} | _] = AuthInstance,
	[{AcctAddress, AcctPort, _} | _] = AcctInstance,
	{ok, Socket} = gen_udp:open(0, [{active, false}, inet, binary]),
	P1 = price(usage, octets, rand:uniform(1000000), rand:uniform(100)),
	OfferId = add_offer([P1], 4),
	ProdRef = add_product(OfferId),
	#service{name = PeerID, password = Password} =  add_service(ProdRef),
	B1 = bucket(octets, rand:uniform(100000)),
	_BId = add_bucket(ProdRef, B1),
	Secret = ct:get_config(radius_shared_secret),
	ReqAuth = radius:authenticator(),
   HiddenPassword = radius_attributes:hide(Secret, ReqAuth, Password),
	authenticate_subscriber(Socket, AuthAddress, AuthPort, PeerID,
			HiddenPassword, Secret, NasID, ReqAuth, RadID1, AcctSessionID),
	RadID2 = RadID1 + 1,
	accounting_start(Socket, AcctAddress, AcctPort,
			PeerID, Secret, NasID, AcctSessionID, RadID2),
	RadID3 = RadID2 + 1,
	accounting_stop(Socket, AcctAddress, AcctPort,
			PeerID, Secret, NasID, AcctSessionID, RadID3).

radius_disconnect_session() ->
	[{userdata, [{doc, "Disconnect a RADIUS accounting session based on usage"}]}].

radius_disconnect_session(Config) ->
	RadID1 = 10,
	NasID = ?config(nas_id, Config),
	AcctSessionID = ocs:generate_identity(),
	{ok, [{auth, AuthInstance}, {acct, AcctInstance}]} = application:get_env(ocs, radius),
	[{AuthAddress, AuthPort, _} | _] = AuthInstance,
	[{AcctAddress, AcctPort, _} | _] = AcctInstance,
	{ok, Socket} = gen_udp:open(0, [{active, false}, inet, binary]),
	P1 = price(usage, octets, rand:uniform(1000000), rand:uniform(100)),
	OfferId = add_offer([P1], 4),
	ProdRef = add_product(OfferId),
	#service{name = PeerID, password = Password} =  add_service(ProdRef),
	B1 = bucket(octets, rand:uniform(100000)),
	_BId = add_bucket(ProdRef, B1),
	Secret = ct:get_config(radius_shared_secret),
	ReqAuth = radius:authenticator(),
   HiddenPassword = radius_attributes:hide(Secret, ReqAuth, Password),
	authenticate_subscriber(Socket, AuthAddress, AuthPort, PeerID,
			HiddenPassword, Secret, NasID, ReqAuth, RadID1, AcctSessionID),
	RadID2 = RadID1 + 1,
	accounting_start(Socket, AcctAddress, AcctPort,
			PeerID, Secret, NasID, AcctSessionID, RadID2),
	RadID3 = RadID2 + 1,
	accounting_interim(Socket, AcctAddress, AcctPort,
			PeerID, Secret, NasID, AcctSessionID, RadID3, 750000123, 750000456),
	RadID4 = RadID3 + 1,
	accounting_stop(Socket, AcctAddress, AcctPort,
			PeerID, Secret, NasID, AcctSessionID, RadID4, 1350000987, 1350000654),
	DiscPort = ?config(radius_disc_port, Config),
	disconnect_request(DiscPort).

radius_multisession_disallowed() ->
	[{userdata, [{doc, "Start multiple RADIUS sessions for a subscriber when
			multiple RADIUS sessions are not allowed. Previous sessions should be disconnected
			allowing the last successfull session to exist."}]}].

radius_multisession_disallowed(Config) ->
	RadID1 = 8,
	NasID = ?config(nas_id, Config),
	AcctSessionID1 = ocs:generate_identity(),
	{ok, [{auth, AuthInstance}, {acct, AcctInstance}]} = application:get_env(ocs, radius),
	[{AuthAddress, AuthPort, _} | _] = AuthInstance,
	[{AcctAddress, AcctPort, _} | _] = AcctInstance,
	{ok, Socket} = gen_udp:open(0, [{active, false}, inet, binary]),
	P1 = price(usage, octets, rand:uniform(1000000), rand:uniform(100)),
	OfferId = add_offer([P1], 4),
	ProdRef = add_product(OfferId),
	#service{name = User, password = Password} =  add_service(ProdRef),
	PeerID = binary_to_list(User),
	B1 = bucket(octets, rand:uniform(100000)),
	_BId = add_bucket(ProdRef, B1),
	Secret = ct:get_config(radius_shared_secret),
	ReqAuth = radius:authenticator(),
	HiddenPassword = radius_attributes:hide(Secret, ReqAuth, Password),
	authenticate_subscriber(Socket, AuthAddress, AuthPort, PeerID,
			HiddenPassword, Secret, NasID, ReqAuth, RadID1, AcctSessionID1),
	RadID2 = RadID1 + 1,
	accounting_start(Socket, AcctAddress, AcctPort,
			PeerID, Secret, NasID, AcctSessionID1, RadID2),
	{ok, #service{multisession = false, session_attributes = SessionList1}}
			= ocs:find_service(PeerID),
	[SessionAttr1] = SessionList1,
	F = fun({_, SessionAttributes}, Nas) ->
		{_, PeerID} = radius_attributes:find(?UserName, SessionAttributes),
		case radius_attributes:find(?NasIdentifier, SessionAttributes) of
			{_, Nas} ->
				ok;
			false ->
				{_, "127.0.0.1"} = radius_attributes:find(?NasIpAddress, SessionAttr1),
				ok
		end
	end,
	ok = F(SessionAttr1, NasID),
	Rad2ID1 = 5,
	NasID2 = "vlkf@example.net",
	AcctSessionID2 = ocs:generate_identity(),
	DiscPort = ?config(radius_disc_port, Config),
	authenticate_subscriber1(Socket, AuthAddress, AuthPort, PeerID,
			HiddenPassword, Secret, NasID2, ReqAuth, Rad2ID1,
			DiscPort, AcctSessionID2),
	ct:sleep(500),
	{ok, #service{multisession = false, session_attributes = SessionList2}}
			= ocs:find_service(PeerID),
	[SessionAttr2] = SessionList2,
	ok = F(SessionAttr2, NasID2),
	Rad2ID2 = Rad2ID1 + 1,
	accounting_start(Socket, AcctAddress, AcctPort, PeerID, Secret, NasID2,
			AcctSessionID2, Rad2ID2),
	Rad2ID3 = Rad2ID2 + 1,
	accounting_stop(Socket, AcctAddress, AcctPort,
			PeerID, Secret, NasID2, AcctSessionID2, Rad2ID3),
	{ok, #service{multisession = false, session_attributes = []}}
			= ocs:find_service(PeerID).

radius_multisession() ->
	[{userdata, [{doc, "Start multiple RADIUS sessions for a subscriber when
			multiple RADIUS sessions are allowed."}]}].

radius_multisession(_Config) ->
	RadID1 = 11,
	NasID1 = "axe1@ap-1.org",
	AcctSessionID1 = ocs:generate_identity(),
	{ok, [{auth, AuthInstance}, {acct, AcctInstance}]} = application:get_env(ocs, radius),
	[{AuthAddress, AuthPort, _} | _] = AuthInstance,
	[{AcctAddress, AcctPort, _} | _] = AcctInstance,
	{ok, Socket} = gen_udp:open(0, [{active, false}, inet, binary]),
	P1 = price(usage, octets, rand:uniform(1000000), rand:uniform(100)),
	OfferId = add_offer([P1], 4),
	ProdRef = add_product(OfferId),
	PeerID = ocs:generate_identity(),
	Password = ocs:generate_identity(),
	State = active,
	{ok, #service{}} = ocs:add_service(PeerID, Password, State,
			ProdRef, [], [], true, true),
	B1 = bucket(octets, rand:uniform(100000)),
	_BId = add_bucket(ProdRef, B1),
	Secret = ct:get_config(radius_shared_secret),
	ReqAuth = radius:authenticator(),
	HiddenPassword = radius_attributes:hide(Secret, ReqAuth, Password),
	%% Authenticate session 1
	authenticate_subscriber(Socket, AuthAddress, AuthPort, PeerID,
			HiddenPassword, Secret, NasID1, ReqAuth, RadID1, AcctSessionID1),
	RadID2 = RadID1 + 1,
	accounting_start(Socket, AcctAddress, AcctPort,
			PeerID, Secret, NasID1, AcctSessionID1, RadID2),
	{ok, #service{multisession = true, session_attributes = SessionList1}}
			= ocs:find_service(PeerID),
	F1 = fun(F1, Session, [H1 | T1]) ->
				case lists:member(H1, Session) of
					true ->
						F1(F1, Session, T1);
					false ->
						not_found
				end;
			(_, _, []) ->
				ok
	end,
	F2 = fun(F2, [{_, H}| T], A) ->
				case F1(F1, H, A) of
					ok ->
						ok;
					not_found ->
						F2(F2, T, A)
				end;
			(_, [], _) ->
				not_found
	end,
	1 = length(SessionList1),
	ok = F2(F2, SessionList1, [{?UserName, PeerID}, {?NasIdentifier, NasID1}]),
	%% Authenticate session 2
	Rad2ID1 = 5,
	NasID2 = "axe2@ap-2.org",
	AcctSessionID2 = ocs:generate_identity(),
	authenticate_subscriber(Socket, AuthAddress, AuthPort, PeerID,
			HiddenPassword, Secret, NasID2, ReqAuth, Rad2ID1, AcctSessionID2),
	ct:sleep(500),
	{ok, #service{multisession = true, session_attributes = SessionList2}}
			= ocs:find_service(PeerID),
	2 = length(SessionList2),
	ok = F2(F2, SessionList2, [{?UserName, PeerID}, {?NasIdentifier, NasID2}]),
	Rad2ID2 = Rad2ID1 + 1,
	accounting_start(Socket, AcctAddress, AcctPort, PeerID, Secret, NasID2,
			AcctSessionID2, Rad2ID2),
	%% Authenticate session 3
	Rad3ID1 = 21,
	NasID3 = "axe3@ap-3.org",
	AcctSessionID3 = ocs:generate_identity(),
	authenticate_subscriber(Socket, AuthAddress, AuthPort, PeerID,
			HiddenPassword, Secret, NasID3, ReqAuth, Rad3ID1, AcctSessionID3),
	ct:sleep(500),
	{ok, #service{multisession = true, session_attributes = SessionList3}}
			= ocs:find_service(PeerID),
	3 = length(SessionList3),
	ok = F2(F2, SessionList3, [{?UserName, PeerID}, {?NasIdentifier, NasID3}]),
	Rad3ID2 = Rad3ID1 + 1,
	accounting_start(Socket, AcctAddress, AcctPort, PeerID, Secret, NasID3,
			AcctSessionID3, Rad3ID2),
	%% Disconnect session 2
	Rad2ID3 = Rad2ID2 + 1,
	accounting_stop(Socket, AcctAddress, AcctPort,
			PeerID, Secret, NasID2, AcctSessionID2, Rad2ID3),
	{ok, #service{multisession = true, session_attributes = SessionList4}}
			= ocs:find_service(PeerID),
	2 = length(SessionList4),
	ok = F2(F2, SessionList4, [{?UserName, PeerID}, {?NasIdentifier, NasID1}]),
	ok = F2(F2, SessionList4, [{?UserName, PeerID}, {?NasIdentifier, NasID3}]).

diameter_accounting() ->
	[{userdata, [{doc, "Initiate and terminate a DIAMETER accounting session"}]}].

diameter_accounting(_Config) ->
	P1 = price(usage, octets, rand:uniform(10000), rand:uniform(100)),
	OfferId = add_offer([P1], 4),
	ProdRef = add_product(OfferId),
	Username = list_to_binary(ocs:generate_identity()),
	Password = ocs:generate_identity(),
	{ok, #service{}} = ocs:add_service(Username, Password, ProdRef, []),
	B1 = bucket(octets, 100000000000),
	_BId = add_bucket(ProdRef, B1),
	Ref = erlang:ref_to_list(make_ref()),
	SId = diameter:session_id(Ref),
	RequestNum = 0,
	Answer0 = diameter_accounting_start(SId, Username, RequestNum),
	#'3gpp_ro_CCA'{'Result-Code' = ?'DIAMETER_BASE_RESULT-CODE_SUCCESS',
			'Auth-Application-Id' = ?RO_APPLICATION_ID,
			'CC-Request-Type' = ?'3GPP_CC-REQUEST-TYPE_INITIAL_REQUEST',
			'CC-Request-Number' = RequestNum,
			'Multiple-Services-Credit-Control' = [MultiServices_CC]} = Answer0,
	#'3gpp_ro_Multiple-Services-Credit-Control'{
			'Granted-Service-Unit' = [GrantedUnits]} = MultiServices_CC,
	#'3gpp_ro_Granted-Service-Unit'{'CC-Total-Octets' = [TotalOctets]} = GrantedUnits,
	NewRequestNum = RequestNum + 1,
	Answer1 = diameter_accounting_stop(SId, Username, NewRequestNum, TotalOctets),
	#'3gpp_ro_CCA'{'Result-Code' = ?'DIAMETER_BASE_RESULT-CODE_SUCCESS',
			'Auth-Application-Id' = ?RO_APPLICATION_ID,
			'CC-Request-Type' = ?'3GPP_CC-REQUEST-TYPE_TERMINATION_REQUEST',
			'CC-Request-Number' = NewRequestNum} = Answer1.

diameter_disconnect_session() ->
	[{userdata, [{doc, "Disconnect a DIAMETER accounting session based on usage"}]}].

diameter_disconnect_session(_Config) ->
	P1 = price(usage, octets, 1000000, 100),
	OfferId = add_offer([P1], 4),
	ProdRef = add_product(OfferId),
	Username = ocs:generate_identity(),
	Password = ocs:generate_identity(),
	{ok, #service{}} = ocs:add_service(Username, Password, ProdRef, []),
	B1 = bucket(octets, 2000000000),
	_BId = add_bucket(ProdRef, B1),
	Ref = erlang:ref_to_list(make_ref()),
	SId = diameter:session_id(Ref),
	RequestNum0 = 0,
	Answer0 = diameter_accounting_start(SId, Username, RequestNum0),
	#'3gpp_ro_CCA'{'Result-Code' = ?'DIAMETER_BASE_RESULT-CODE_SUCCESS',
			'Auth-Application-Id' = ?RO_APPLICATION_ID,
			'CC-Request-Type' = ?'3GPP_CC-REQUEST-TYPE_INITIAL_REQUEST',
			'CC-Request-Number' = RequestNum0,
			'Multiple-Services-Credit-Control' = [MultiServices_CC0]} = Answer0,
	#'3gpp_ro_Multiple-Services-Credit-Control'{
			'Granted-Service-Unit' = [GrantedUnits0]} = MultiServices_CC0,
	#'3gpp_ro_Granted-Service-Unit'{'CC-Total-Octets' = [Grant0]} = GrantedUnits0,
	RequestNum1 = RequestNum0 + 1,
	Answer1 = diameter_accounting_interim(SId, Username, RequestNum1, Grant0 - 123),
	#'3gpp_ro_CCA'{'Result-Code' = ?'DIAMETER_BASE_RESULT-CODE_SUCCESS',
			'Auth-Application-Id' = ?RO_APPLICATION_ID,
			'CC-Request-Type' = ?'3GPP_CC-REQUEST-TYPE_UPDATE_REQUEST',
			'CC-Request-Number' = RequestNum1,
			'Multiple-Services-Credit-Control' = [MultiServices_CC1]} = Answer1,
	#'3gpp_ro_Multiple-Services-Credit-Control'{
			'Granted-Service-Unit' = [GrantedUnits1]} = MultiServices_CC1,
	#'3gpp_ro_Granted-Service-Unit'{'CC-Total-Octets' = [Grant1]} = GrantedUnits1,
	RequestNum2 = RequestNum1 + 1,
	Answer2 = diameter_accounting_interim(SId, Username, RequestNum2, Grant1 + 123),
	#'3gpp_ro_CCA'{'Result-Code' = ?'DIAMETER_BASE_RESULT-CODE_SUCCESS',
			'Auth-Application-Id' = ?RO_APPLICATION_ID,
			'CC-Request-Type' = ?'3GPP_CC-REQUEST-TYPE_UPDATE_REQUEST',
			'CC-Request-Number' = RequestNum2,
			'Multiple-Services-Credit-Control' = [MultiServices_CC2]} = Answer2,
	#'3gpp_ro_Multiple-Services-Credit-Control'{
			'Granted-Service-Unit' = [GrantedUnits2]} = MultiServices_CC2,
	#'3gpp_ro_Granted-Service-Unit'{'CC-Total-Octets' = [Grant2]} = GrantedUnits2,
	RequestNum3 = RequestNum2 + 1,
	Answer3 = diameter_accounting_interim(SId, Username, RequestNum3, Grant2 + 1234567890),
	#'3gpp_ro_CCA'{'Result-Code' = ?'IETF_RESULT-CODE_CREDIT_LIMIT_REACHED',
			'Auth-Application-Id' = ?RO_APPLICATION_ID,
			'CC-Request-Type' = ?'3GPP_CC-REQUEST-TYPE_UPDATE_REQUEST',
			'CC-Request-Number' = RequestNum3} = Answer3.

diameter_sms() ->
	[{userdata, [{doc, "DIAMETER accouting for event base usage"}]}].

diameter_sms(_Config) ->
	PackagePrice = rand:uniform(5),
	PackageSize = rand:uniform(5),
	Balance = (rand:uniform(5) * 5) div rand:uniform(5),
	P1 = price(usage, messages, PackageSize, PackagePrice),
	OfferId = add_offer([P1], 11),
	ProdRef = add_product(OfferId),
	CalledParty = ocs:generate_identity(),
	CallingParty = ocs:generate_identity(),
	Password = ocs:generate_password(),
	{ok, #service{}} = ocs:add_service(CalledParty, Password, ProdRef, []),
	B1 = bucket(messages, Balance),
	_BId = add_bucket(ProdRef, B1),
	NumOfEvents = Balance div rand:uniform(5),
	{ok, EnvList} = application:get_env(ocs, diameter),
	{acct, [{Address, _Port, _Options } | _]} = lists:keyfind(acct, 1, EnvList),
	{ok, _} = ocs:add_client(Address, undefined, diameter, undefined, true),
	Ref = erlang:ref_to_list(make_ref()),
	SId = diameter:session_id(Ref),
	Subscription_Id = #'3gpp_ro_Subscription-Id'{
			'Subscription-Id-Type' = ?'3GPP_SUBSCRIPTION-ID-TYPE_END_USER_E164',
			'Subscription-Id-Data' = CalledParty},
	RequestedUnits = #'3gpp_ro_Requested-Service-Unit' {
			'CC-Service-Specific-Units' = [NumOfEvents]},
	ServiceInformation = #'3gpp_ro_Service-Information'{'IMS-Information' =
			[#'3gpp_ro_IMS-Information'{
					'Node-Functionality' = ?'3GPP_NODE-FUNCTIONALITY_AS',
					'Calling-Party-Address' = [list_to_binary("tel:" ++ CalledParty)],
					'Called-Party-Address' = [list_to_binary("tel:" ++ CallingParty)]}]},
	MultiServices_CC0 = #'3gpp_ro_Multiple-Services-Credit-Control'{
			'Requested-Service-Unit' = [RequestedUnits]},
	RequestNum0 = 0,
	CC_CCR0 = #'3gpp_ro_CCR'{'Session-Id' = SId,
			'Auth-Application-Id' = ?RO_APPLICATION_ID,
			'Service-Context-Id' = "nas45.32274.org",
			'User-Name' = [CalledParty],
			'CC-Request-Type' = ?'3GPP_CC-REQUEST-TYPE_INITIAL_REQUEST',
			'CC-Request-Number' = RequestNum0,
			'Event-Timestamp' = [calendar:universal_time()],
			'Subscription-Id' = [Subscription_Id],
			'Multiple-Services-Credit-Control' = [MultiServices_CC0],
			'Service-Information' = [ServiceInformation]},
	{ok, Answer0} = diameter:call(?SVC_ACCT, cc_app_test, CC_CCR0, []),
	#'3gpp_ro_CCA'{'Result-Code' = ?'DIAMETER_BASE_RESULT-CODE_SUCCESS',
			'Auth-Application-Id' = ?RO_APPLICATION_ID,
			'CC-Request-Type' = ?'3GPP_CC-REQUEST-TYPE_INITIAL_REQUEST',
			'CC-Request-Number' = RequestNum,
			'Multiple-Services-Credit-Control' = [MultiServices_CC1]} = Answer0,
	#'3gpp_ro_Multiple-Services-Credit-Control'{
			'Granted-Service-Unit' = [GrantedUnits]} = MultiServices_CC1,
	#'3gpp_ro_Granted-Service-Unit'{'CC-Service-Specific-Units' = [NumOfEvents]} = GrantedUnits,
	NewRequestNum = RequestNum + 1,
	UsedUnits = #'3gpp_ro_Used-Service-Unit'{'CC-Service-Specific-Units' = [NumOfEvents]},
	MultiServices_CC2 = #'3gpp_ro_Multiple-Services-Credit-Control'{
			'Used-Service-Unit' = [UsedUnits]},
	CC_CCR1 = #'3gpp_ro_CCR'{'Session-Id' = SId,
			'Auth-Application-Id' = ?RO_APPLICATION_ID,
			'Service-Context-Id' = "nas45.32251@3gpp.org" ,
			'User-Name' = [CalledParty],
			'CC-Request-Type' = ?'3GPP_CC-REQUEST-TYPE_TERMINATION_REQUEST',
			'CC-Request-Number' = NewRequestNum,
			'Event-Timestamp' = [calendar:universal_time()],
			'Multiple-Services-Credit-Control' = [MultiServices_CC2],
			'Subscription-Id' = [Subscription_Id],
			'Service-Information' = [ServiceInformation]},
	{ok, Answer1} = diameter:call(?SVC_ACCT, cc_app_test, CC_CCR1, []),
	#'3gpp_ro_CCA'{'Result-Code' = ?'DIAMETER_BASE_RESULT-CODE_SUCCESS',
			'Auth-Application-Id' = ?RO_APPLICATION_ID,
			'CC-Request-Type' = ?'3GPP_CC-REQUEST-TYPE_TERMINATION_REQUEST',
			'CC-Request-Number' = NewRequestNum} = Answer1.

%%---------------------------------------------------------------------
%%  Internal functions
%%---------------------------------------------------------------------
authenticate_subscriber(Socket, Address,
		Port, PeerID, Password, Secret, NasID, ReqAuth, RadID, AcctSessionID) ->
	RadAttribute = radius_attributes:add(?UserPassword, Password, []),
	access_request(Socket, Address, Port, PeerID, Secret,
			NasID, ReqAuth, RadID, AcctSessionID, RadAttribute),
	access_accept(Socket, Address, Port, RadID).

accounting_start(Socket, Address, Port,
		PeerID, Secret, NasID, AcctSessionID, RadID) ->
	ReqAuth = accounting_request(?AccountingStart, Socket,
			Address, Port, PeerID, Secret, NasID, AcctSessionID, RadID, []),
	accounting_response(Socket, Address, Port, Secret, RadID, ReqAuth).

accounting_interim(Socket, Address, Port, PeerID,
		Secret, NasID, AcctSessionID, RadID, InputOctets, OutputOctets) ->
	A0 = radius_attributes:add(?AcctInputOctets, InputOctets rem (1 bsl 32), []),
	A1 = radius_attributes:add(?AcctOutputOctets, OutputOctets rem (1 bsl 32), A0),
	A2 = radius_attributes:add(?AcctInputGigawords, InputOctets div (1 bsl 32), A1),
	A3 = radius_attributes:add(?AcctOutputGigawords, OutputOctets div (1 bsl 32), A2),
	ReqAuth = accounting_request(?AccountingInterimUpdate, Socket,
			Address, Port, PeerID, Secret, NasID, AcctSessionID, RadID, A3),
	accounting_response(Socket, Address, Port, Secret, RadID, ReqAuth).

accounting_stop(Socket, Address, Port, PeerID, Secret, NasID, AcctSessionID, RadID) ->
	accounting_stop(Socket, Address, Port, PeerID,
			Secret, NasID, AcctSessionID, RadID, 100, 50).
accounting_stop(Socket, Address, Port, PeerID,
		Secret, NasID, AcctSessionID, RadID, InputOctets, OutputOctets) ->
	A0 = radius_attributes:add(?AcctInputOctets, InputOctets rem (1 bsl 32), []),
	A1 = radius_attributes:add(?AcctOutputOctets, OutputOctets rem (1 bsl 32), A0),
	A2 = radius_attributes:add(?AcctInputGigawords, InputOctets div (1 bsl 32), A1),
	A3 = radius_attributes:add(?AcctOutputGigawords, OutputOctets div (1 bsl 32), A2),
	ReqAuth = accounting_request(?AccountingStop, Socket,
			Address, Port, PeerID, Secret, NasID, AcctSessionID, RadID, A3),
	accounting_response(Socket, Address, Port, Secret, RadID, ReqAuth).

disconnect_request(Port) ->
	{ok, Socket} = gen_udp:open(Port, [{active, false}, inet, binary]),
	{ok, {OCSAddr, OCSPort, DiscReq}} = gen_udp:recv(Socket, 0),
	#radius{code = ?DisconnectRequest, id = DiscReqID} = radius:codec(DiscReq),
	DiscAckAuth = radius:authenticator(),
	DiscAckAttr0 = radius_attributes:new(),
	DiscAckAttr1 = radius_attributes:add(?AcctTerminateCause, 6, DiscAckAttr0),
	DiscAckAttrBin = radius_attributes:codec(DiscAckAttr1),
	DiscAckRec = #radius{code = ?DisconnectAck, id = DiscReqID,
			authenticator = DiscAckAuth, attributes = DiscAckAttrBin},
	DiscAck = radius:codec(DiscAckRec),
	ok = gen_udp:send(Socket, OCSAddr, OCSPort, DiscAck),
	ok =  gen_udp:close(Socket).

access_accept(Socket, Address, Port, RadID) ->
	receive_radius(?AccessAccept, Socket, Address, Port, RadID).

accounting_response(Socket, Address, Port, Secret, RadID, ReqAuth) ->
	#radius{id = RadID, authenticator = RespAuth,
		attributes = Attributes}
		= receive_radius(?AccountingResponse, Socket, Address, Port, RadID),
	AttributesLength = size(Attributes) + 20,
	RespAuth = binary_to_list(crypto:hash(md5,
			[<<?AccountingResponse, RadID, AttributesLength:16>>,
			ReqAuth, Attributes, Secret])).

receive_radius(Code, Socket, Address, Port, RadID) ->
	{ok, {Address, Port, RespPacket}} = gen_udp:recv(Socket, 0),
	#radius{code = Code, id = RadID} = radius:codec(RespPacket).

access_request(Socket, Address, Port, UserName, Secret,
		NasID, Auth, RadID, AcctSessionID, RadAttributes)
		when is_binary(UserName) ->
	access_request(Socket, Address, Port, binary_to_list(UserName),
			Secret, NasID, Auth, RadID, AcctSessionID, RadAttributes);
access_request(Socket, Address, Port, UserName, Secret,
		NasID, Auth, RadID, AcctSessionID, RadAttributes) ->
	A1 = session_attributes(UserName, NasID, AcctSessionID, RadAttributes),
	A2 = radius_attributes:add(?MessageAuthenticator, <<0:128>>, A1),
	Request1 = #radius{code = ?AccessRequest, id = RadID,
		authenticator = Auth, attributes = A2},
	ReqPacket1 = radius:codec(Request1),
	MsgAuth1 = crypto:hmac(md5, Secret, ReqPacket1),
	A3 = radius_attributes:store(?MessageAuthenticator, MsgAuth1, A2),
	Request2 = Request1#radius{attributes = A3},
	ReqPacket2 = radius:codec(Request2),
	gen_udp:send(Socket, Address, Port, ReqPacket2).

accounting_request(StatusType, Socket, Address, Port,
		UserName, Secret, NasID, AcctSessionID, RadID, RadAttributes)
		when is_binary(UserName) ->
	accounting_request(StatusType, Socket, Address, Port,
			binary_to_list(UserName), Secret, NasID, AcctSessionID,
			RadID, RadAttributes);
accounting_request(StatusType, Socket, Address, Port,
		UserName, Secret, NasID, AcctSessionID, RadID, RadAttributes) ->
	A1 = session_attributes(UserName, NasID, AcctSessionID, RadAttributes),
	A2 = radius_attributes:add(?AcctStatusType, StatusType, A1),
	AccAttributes = radius_attributes:codec(A2),
	Acc1Length = size(AccAttributes) + 20,
	AccAuthenticator = crypto:hash(md5, [<<?AccountingRequest, RadID,
			Acc1Length:16, 0:128>>, AccAttributes, Secret]),
	AccountingRequest = #radius{code = ?AccountingRequest, id = RadID,
			authenticator = AccAuthenticator, attributes = AccAttributes},
	AccPacket = radius:codec(AccountingRequest),
	ok = gen_udp:send(Socket, Address, Port, AccPacket),
	AccAuthenticator.

session_attributes(UserName, NasID, AcctSessionID, RadAttributes) ->
	A1 = radius_attributes:add(?UserName, UserName, RadAttributes),
	A2 = radius_attributes:add(?NasPort, 19, A1),
	A3 = radius_attributes:add(?NasIpAddress, {127, 0, 0,1}, A2),
	A4 = radius_attributes:add(?NasIdentifier, NasID, A3),
	A5 = radius_attributes:add(?CallingStationId,"DE-AD-BE-EF-FE-ED", A4),
	A6 = radius_attributes:add(?CalledStationId,"BA-DF-AD-CA-DD-AD:TestSSID", A5),
	A7 = radius_attributes:add(?AcctSessionId, AcctSessionID, A6),
	radius_attributes:add(?ServiceType, 2, A7).

%% @doc Add a transport capability to diameter service.
%% @hidden
connect(SvcName, Address, Port, Transport) when is_atom(Transport) ->
	connect(SvcName, [{connect_timer, 30000} | transport_opts(Address, Port, Transport)]).

%% @hidden
connect(SvcName, Opts)->
	diameter:add_transport(SvcName, {connect, Opts}).

%% @hidden
client_acct_service_opts(Options) ->
	{ok, Hostname} = inet:gethostname(),
	Options ++ [{'Origin-Host', Hostname},
		{'Origin-Realm', "testdomain.com"},
		{'Vendor-Id', 10415},
		{'Product-Name', "SigScale Test Client (Acct)"},
		{'Auth-Application-Id', [?BASE_APPLICATION_ID, ?RO_APPLICATION_ID]},
		{string_decode, false},
		{restrict_connections, false},
		{application, [{alias, base_app_test},
				{dictionary, diameter_gen_base_rfc6733},
				{module, diameter_test_client_cb}]},
		{application, [{alias, cc_app_test},
				{dictionary, diameter_gen_3gpp_ro_application},
				{module, diameter_test_client_cb}]}].

%% @hidden
transport_opts(Address, Port, Trans) when is_atom(Trans) ->
	transport_opts1({Trans, Address, Address, Port}).

%% @hidden
transport_opts1({Trans, LocalAddr, RemAddr, RemPort}) ->
	[{transport_module, Trans},
		{transport_config, [{raddr, RemAddr},
		{rport, RemPort},
		{reuseaddr, true}
		| [{ip, LocalAddr}]]}].

%% @hidden
diameter_accounting_start(SId, Username, RequestNum) ->
	Subscription_Id = #'3gpp_ro_Subscription-Id'{
			'Subscription-Id-Type' = ?'3GPP_SUBSCRIPTION-ID-TYPE_END_USER_E164',
			'Subscription-Id-Data' = Username},
	RequestedUnits = #'3gpp_ro_Requested-Service-Unit' {
			'CC-Total-Octets' = [1000000000]},
	MultiServices_CC = #'3gpp_ro_Multiple-Services-Credit-Control'{
			'Requested-Service-Unit' = [RequestedUnits]},
	ServiceInformation = #'3gpp_ro_Service-Information'{'IMS-Information' =
			[#'3gpp_ro_IMS-Information'{
					'Node-Functionality' = ?'3GPP_NODE-FUNCTIONALITY_AS',
					'Calling-Party-Address' = [<<"tel:110493422">>],
					'Called-Party-Address' = [<<"tel:0110493488">>]}]},
	CC_CCR = #'3gpp_ro_CCR'{'Session-Id' = SId,
			'Auth-Application-Id' = ?RO_APPLICATION_ID,
			'Service-Context-Id' = "nas45.32251@3gpp.org",
			'User-Name' = [Username],
			'CC-Request-Type' = ?'3GPP_CC-REQUEST-TYPE_INITIAL_REQUEST',
			'CC-Request-Number' = RequestNum,
			'Event-Timestamp' = [calendar:universal_time()],
			'Subscription-Id' = [Subscription_Id],
			'Multiple-Services-Credit-Control' = [MultiServices_CC],
			'Service-Information' = [ServiceInformation]},
	{ok, Answer} = diameter:call(?SVC_ACCT, cc_app_test, CC_CCR, []),
	Answer.
	
%% @hidden
diameter_accounting_stop(SId, Username, RequestNum, Usage) ->
	Subscription_Id = #'3gpp_ro_Subscription-Id'{
			'Subscription-Id-Type' = ?'3GPP_SUBSCRIPTION-ID-TYPE_END_USER_E164',
			'Subscription-Id-Data' = Username},
	UsedUnits = #'3gpp_ro_Used-Service-Unit'{'CC-Total-Octets' = [Usage]},
	MultiServices_CC = #'3gpp_ro_Multiple-Services-Credit-Control'{
			'Used-Service-Unit' = [UsedUnits]},
	ServiceInformation = #'3gpp_ro_Service-Information'{'IMS-Information' =
			[#'3gpp_ro_IMS-Information'{
					'Node-Functionality' = ?'3GPP_NODE-FUNCTIONALITY_AS',
					'Calling-Party-Address' = [<<"tel:110493422">>],
					'Called-Party-Address' = [<<"tel:0110493488">>]}]},
	CC_CCR = #'3gpp_ro_CCR'{'Session-Id' = SId,
			'Auth-Application-Id' = ?RO_APPLICATION_ID,
			'Service-Context-Id' = "nas45.32251@3gpp.org" ,
			'User-Name' = [Username],
			'CC-Request-Type' = ?'3GPP_CC-REQUEST-TYPE_TERMINATION_REQUEST',
			'CC-Request-Number' = RequestNum,
			'Event-Timestamp' = [calendar:universal_time()],
			'Multiple-Services-Credit-Control' = [MultiServices_CC],
			'Subscription-Id' = [Subscription_Id],
			'Service-Information' = [ServiceInformation]},
	{ok, Answer} = diameter:call(?SVC_ACCT, cc_app_test, CC_CCR, []),
	Answer.

%% @hidden
diameter_accounting_interim(SId, Username, RequestNum, Usage) ->
	Subscription_Id = #'3gpp_ro_Subscription-Id'{
			'Subscription-Id-Type' = ?'3GPP_SUBSCRIPTION-ID-TYPE_END_USER_E164',
			'Subscription-Id-Data' = Username},
	UsedUnits = #'3gpp_ro_Used-Service-Unit'{'CC-Total-Octets' = [Usage]},
	RequestedUnits = #'3gpp_ro_Requested-Service-Unit' {
			'CC-Total-Octets' = [375123456]},
	MultiServices_CC = #'3gpp_ro_Multiple-Services-Credit-Control'{
			'Used-Service-Unit' = [UsedUnits],
			'Requested-Service-Unit' = [RequestedUnits]},
	ServiceInformation = #'3gpp_ro_Service-Information'{'IMS-Information' =
			[#'3gpp_ro_IMS-Information'{
					'Node-Functionality' = ?'3GPP_NODE-FUNCTIONALITY_AS',
					'Calling-Party-Address' = [<<"tel:110493422">>],
					'Called-Party-Address' = [<<"tel:0110493488">>]}]},
	CC_CCR = #'3gpp_ro_CCR'{'Session-Id' = SId,
			'Auth-Application-Id' = ?RO_APPLICATION_ID,
			'Service-Context-Id' = "nas45.32251@3gpp.org" ,
			'User-Name' = [Username],
			'CC-Request-Type' = ?'3GPP_CC-REQUEST-TYPE_UPDATE_REQUEST',
			'CC-Request-Number' = RequestNum,
			'Event-Timestamp' = [calendar:universal_time()],
			'Multiple-Services-Credit-Control' = [MultiServices_CC],
			'Subscription-Id' = [Subscription_Id],
			'Service-Information' = [ServiceInformation]},
	{ok, Answer} = diameter:call(?SVC_ACCT, cc_app_test, CC_CCR, []),
	Answer.
	
authenticate_subscriber1(Socket, Address,
		Port, PeerID, Password, Secret, NasID, ReqAuth, RadID,
		DiscPort, AcctSessionID) ->
	RadAttribute = radius_attributes:add(?UserPassword, Password, []),
	access_request(Socket, Address, Port, PeerID, Secret,
			NasID, ReqAuth, RadID, AcctSessionID, RadAttribute),
	disconnect_request(DiscPort),
	access_accept(Socket, Address, Port, RadID).

%% @hidden
price(Type, Units, Size, Amount) ->
	#price{name = ocs:generate_identity(),
			type = Type, units = Units,
			size = Size, amount = Amount}.

%% @hidden
bucket(Units, RA) ->
	#bucket{units = Units, remain_amount = RA,
		start_date = erlang:system_time(?MILLISECOND),
		end_date = erlang:system_time(?MILLISECOND) + 2592000000}.

%% @hidden
add_offer(Prices, Spec) when is_integer(Spec) ->
	add_offer(Prices, integer_to_list(Spec));
add_offer(Prices, Spec) ->
	Offer = #offer{name = ocs:generate_identity(),
	price = Prices, specification = Spec},
	{ok, #offer{name = OfferId}} = ocs:add_offer(Offer),
	OfferId.

%% @hidden
add_product(OfferId) ->
	add_product(OfferId, []).
add_product(OfferId, Chars) ->
	{ok, #product{id = ProdRef}} = ocs:add_product(OfferId, Chars),
	ProdRef.

%% @hidden
add_service(ProdRef) ->
	{ok, Service} =
			ocs:add_service(ocs:generate_identity(), ocs:generate_password(),
			ProdRef, []),
	Service.

%% @hidden
add_bucket(ProdRef, Bucket) ->
	{ok, _, #bucket{id = BId}} = ocs:add_bucket(ProdRef, Bucket),
	BId.
