%% Copyright (c) 2011, Lars-Ake Fredlund
%% All rights reserved.
%%
%% Redistribution and use in source and binary forms, with or without
%% modification, are permitted provided that the following conditions are met:
%%     %% Redistributions of source code must retain the above copyright
%%       notice, this list of conditions and the following disclaimer.
%%     %% Redistributions in binary form must reproduce the above copyright
%%       notice, this list of conditions and the following disclaimer in the
%%       documentation and/or other materials provided with the distribution.
%%     %% Neither the name of the copyright holders nor the
%%       names of its contributors may be used to endorse or promote products
%%       derived from this software without specific prior written permission.
%%
%% THIS SOFTWARE IS PROVIDED BY THE COPYRIGHT HOLDERS AND CONTRIBUTORS ''AS IS''
%% AND ANY EXPRESS OR IMPLIED WARRANTIES, INCLUDING, BUT NOT LIMITED TO, THE 
%% IMPLIED WARRANTIES OF MERCHANTABILITY AND FITNESS FOR A PARTICULAR PURPOSE 
%% ARE DISCLAIMED. IN NO EVENT SHALL THE COPYRIGHT HOLDERS AND CONTRIBUTORS 
%% BE LIABLE FOR ANY DIRECT, INDIRECT, INCIDENTAL, SPECIAL, EXEMPLARY, OR 
%% CONSEQUENTIAL DAMAGES (INCLUDING, BUT NOT LIMITED TO, PROCUREMENT OF 
%% SUBSTITUTE GOODS OR SERVICES; LOSS OF USE, DATA, OR PROFITS; OR 
%% BUSINESS INTERRUPTION) HOWEVER CAUSED AND ON ANY THEORY OF LIABILITY, 
%% WHETHER IN CONTRACT, STRICT LIABILITY, OR TORT (INCLUDING NEGLIGENCE OR 
%% OTHERWISE) ARISING IN ANY WAY OUT OF THE USE OF THIS SOFTWARE, EVEN IF 
%% ADVISED OF THE POSSIBILITY OF SUCH DAMAGE.

%% @doc This module implements a facility for invoking Java code
%% (methods, constructors, fields) from Erlang, using the JInterface library.
%% @author Lars-Ake Fredlund (lfredlund@fi.upm.es)
%% @copyright 2011 Lars-Ake Fredlund
%%

%% New features?
%%
%% - Supporting synchronized? This possibly means to lock, and synchronize
%% on a variable, a particular thread in JavaErlang until it is unlocked
%% (possible on the level of JNI).
%%
%% - Permit calling constructors and methods on non-public classes, and
%% non-public constructors and methods of public classes.
%%
%% - If a field is final, don't generate a setter function.
%%
%% - Supporting long node names.
%%

-module(java).


-include_lib("kernel/include/file.hrl").

-record(node,
	{node_name=void,node_pid=void,port_pid=void,node_id=void,
	 node_node,
	 options,symbolic_name,
	 unix_pid=void,ping_retry=5000,connect_timeout=1000,
	 max_java_start_tries=3,call_timeout,num_start_tries=0}).

-include("class.hrl").

-export([init/1]).
-export([start_node/0,start_node/1,nodes/0,symbolic_name/1]).
-export([default_options/0,version/0]). 
-export([free/1,reset/1,terminate/1,terminate_all/0]).
-export([brutally_terminate/1,recreate_node/1]).
-export([node_id/1]).
-export([new/3,new/4]).
-export([call/3,call/4,call_static/4,call_static/5]).
-export([set_timeout/1]).
-export([get/2,get_static/3,set/3,set_static/4]).
-export([is_object_ref/1]).
-export([array_to_list/1,string_to_list/1,list_to_string/2,list_to_array/3,convert/3]).
-export([getClassName/1,getSimpleClassName/1,instanceof/2,is_subtype/3]).
-export([identity/2]).
-export([print_stacktrace/1,get_stacktrace/1]).
-export([set_loglevel/1,format/2,format/3]).
-export_type([node_id/0,object_ref/0]).

%% Private
-export([javaCall/3]).
-export([get_option/2]).
-export([finalComponent/1]).
-export([find_class/1]).
-export([node_lookup/1]).
-export([run_java/7]).
-export([terminate_brutally/1]).

-include("debug.hrl").

-type loglevel() ::
  all | none | 
  alert | critical | debug | emergency | error | info | notice | warning.

-type option() ::
    {symbolic_name,string()}
    | {java_class,string()}
    | {add_to_java_classpath,[string()]}
    | {java_classpath,[string()]}
    | {java_exception_as_value,boolean()}
    | {java_verbose,string()}
    | {java_executable,string()}
    | {erlang_remote,string()}
    | {log_level,loglevel()}
    | {call_timeout,integer() | infinity}.
%% <ul>
%% <li>`symbolic_name' provides a symbolic name for the node.</li>
%% <li>`java_classpath' provides a classpath to the Java executable.
%% The default classpath includes the OtpErlang.jar library, and
%% the Java class files needed by the JavaErl library.</li>
%% <li>`add_to_java_classpath' adds additional entries to an
%% existing classpath established by java_classpath.</li>
%% <li>`java_exception_as_value' determines whether exceptions
%% generated by a Java runtime is delivered as a tuple
%% "{java_exception,Object}" or as an Erlang exception
%% with the above tuple as cause.</li>
%% <li>`java_executable' determines which program will be used
%% to start the Java interpreter (by default "java").</li>
%% <li>`java_verbose' provides diagnostic output from the 
%% Java interface class using the Java standard logger.</li>
%% <li>`erlang_remote' specifies a (possibly remote)
%% Erlang node which is responsible
%% for starting the new Java node.</li>
%% <li>`call_timeout' sets a timeout value for all calls 
%% to Java from Erlang (default 10 seconds).</li>
%% </ul>
 
-opaque node_id() :: integer().
%%-type node_id() :: integer().
%% Identifies a connected Java node.

%% Likely to change.
-opaque object_type() :: object | executable | thread.

-opaque object_ref() :: {object_type(), integer(), node_id()}.
%%-type object_ref() :: {atom(), integer(), node_id()}.
%% A Java object reference.

-type class_name() :: atom() | string().
%% A Java classname, e.g., the quoted atom 'java.lang.Integer'.

-type method_name() :: atom().
%% A name of a Java method, e.g., the atom 'toString'.

-type attribute_name() :: atom().
%% A name of a Java attribute, represented as an atom.

-type type() :: primitive_type() | class_name() | array_type().
%% The representation of a Java types as an Erlang term.

-type array_type() :: {array,type(),integer()}.

-type value() :: object_ref() | number() |
                 null | true | false | void | array_value() |
                 value_spec().

-type java_number() :: integer() | float().

-type value_spec() :: {int_type(), integer()} |
                      {float_type(), float()} |
                      {class_name, object_ref()} |
                      {array_type(), array_value()}.

-type array_value() :: string() | [value()].

-type primitive_type() :: int_type() | float_type().

-type number_type() :: int_type() | float_type().
-type int_type() :: int | long | short | char | byte .
-type float_type() :: float | double.


%% @doc Starts a Java node and establises the connection
%% to Erlang. Returns a Java library "node identifier" (not a normal
%% Erlang node identifier).
%%
-spec start_node() -> {ok,node_id()} | {error,any()}.
start_node() ->
  start_node([]).

%% @doc Starts a Java node and establishes the connection
%% to Erlang. UserOptions provides options for how
%% Java is started.
%% Returns a "Java library node identifier" (not a normal
%% Erlang node identifier).
%% To make your Java classes (and Jar files) visible to the library
%% the option ``add_to_java_classpath'' should be provided to
%% ``java:start_node/1''. An example:<br/>
%% ```
%% {ok,NodeId} = java:start_node([{add_to_java_classpath,["classes"]}]).
%% '''
%% Adds the directory ``classes''
%% to the classpath of the started Java interpreter.
%%
-spec start_node([option()]) -> {ok,node_id()} | {error,any()}.
start_node(UserOptions) ->
  case whereis(net_kernel) of
    undefined ->
      format
	(error,
	 "*** Error: net_kernel system process is not running.~n"++
	 "Make sure to start erlang using \"erl -sname nodename ...\"~nor "++
	 "call net_kernel:start/1~n~n"),
      throw(net_kernel_undefined);
    _ ->
      ok
  end,
  Options = UserOptions++default_options(),
  check_options(Options),
  LogLevel = proplists:get_value(log_level,Options),
  init([{log_level,LogLevel}]),
  CallTimeout = proplists:get_value(call_timeout,Options),
  SymbolicName = proplists:get_value(symbolic_name,Options,void),
  NodeNode = proplists:get_value(erlang_remote,Options,node()),
  PreNode =
    #node{options=Options,
	  call_timeout=CallTimeout,
	  node_node=NodeNode,
	  symbolic_name=SymbolicName},
  spawn_java(PreNode,get_java_node_id()).
  

spawn_java(PreNode,PreNodeId) ->
  SymbolicName = PreNode#node.symbolic_name,
  if PreNode#node.num_start_tries>=PreNode#node.max_java_start_tries ->
      format(error,"*** Error: ~p: failed to start Java~n",[SymbolicName]),
      {error,too_many_tries};
     true ->
      NodeId = PreNodeId+99,
      Options = PreNode#node.options,
      JavaVerbose = proplists:get_value(java_verbose,Options),
      ClassPath = compute_classpath(Options),
      NodeName = javaNodeName(NodeId,PreNode),
      PortPid = 
	spawn
	  (PreNode#node.node_node,
	   ?MODULE,
	   run_java,
	   [
	    NodeId,
	    NodeName,
	    SymbolicName,
	    proplists:get_value(java_executable,Options),
	    JavaVerbose,ClassPath,
	    proplists:get_value(java_class,Options)
	   ]),
      %%io:format("spawned java ~p~n",[PortPid]),
      PreNode1 =
	PreNode#node{node_id=NodeId,
		     node_name=NodeName,
		     port_pid=PortPid,
		     symbolic_name=SymbolicName},
      case connectToNode(PreNode1) of
	{ok,Node} ->
	  java:format
	    (debug,"~p: connect succeeded with pid ~p~n",
	     [Node#node.symbolic_name,Node#node.node_pid]),
	  node_store(Node),
	  java:format
	    (debug,
	     "~p: fresh connection to ~p established~n",
	     [Node#node.symbolic_name,NodeId]),
	  {ok,NodeId};
	{error,Reason} ->
	  java:format
	    (debug,
	     "~p: failed to connect at try ~p with reason ~p~n",
	     [PreNode1#node.symbolic_name,
	      PreNode1#node.num_start_tries,Reason]),
	  spawn_java
	    (PreNode1#node{num_start_tries=PreNode1#node.num_start_tries+1},
	     NodeId)
      end
  end.

compute_classpath(Options) ->
  ClassPath =
    proplists:get_value(java_classpath,Options),
  AllAdditionals =
    proplists:get_all_values(add_to_java_classpath,Options),
  lists:foldl(fun (CPs,CP) -> CPs++CP end, ClassPath, AllAdditionals).

check_options(Options) ->
  lists:foreach
    (fun (Option) ->
	 OptionName = 
	   case Option of
	     {Name,_} when is_atom(Name) -> Name;
	     Name when is_atom(Name) -> Name
	   end,
	 case lists:member
	   (OptionName,
	    [symbolic_name,log_level,
	     erlang_remote,
	     java_class,java_classpath,add_to_java_classpath,
	     java_exception_as_value,java_verbose,
	     java_executable,call_timeout]) of
	   true -> ok;
	   false ->
	     format
	       (error,
		"*** error: option ~p to java:start_node/2 not understood~n",
		[OptionName]),
	     throw(badarg)
	 end
     end, Options).

%% @private
get_option(Option,NodeId) ->
  {ok,Node} = node_lookup(NodeId),
  proplists:get_value(Option,Node#node.options).

get_option(Option,NodeId,Default) ->
  {ok,Node} = node_lookup(NodeId),
  proplists:get_value(Option,Node#node.options,Default).

get_java_node_id() ->
  ets:update_counter(java_nodes,java_node_counter,1).

%% @private
run_java(Identity,NodeName,Name,Executable,Verbose,Paths,Class) ->
  ClassPath = 
    case combine_paths(Paths) of
      "" -> [];
      PathSpec -> ["-cp",PathSpec]
    end,
  VerboseArg = if Verbose=/=undefined -> ["-loglevel",Verbose]; true -> [] end,
  Args =
    ClassPath++
    [Class,NodeName]++
    VerboseArg,
  format
    (info,
     "~p: starting Java node at ~p with command~n~s and args ~p~n",
     [Name,
      net_adm:localhost(),
      Executable,Args]),
  Port =
    open_port
      ({spawn_executable,Executable},
       [{line,1000},stderr_to_stdout,{args,Args}]),
  java_reader(Port,Identity).

combine_paths(Paths) ->
  Combinator = 
    case runs_on_windows() of
      true -> ";";
      _ -> ":"
    end,
  combine_paths(Combinator,Paths).

combine_paths(_,[]) ->  "";
combine_paths(_,[P]) ->  P;
combine_paths(Combinator,[P|Rest]) -> P++Combinator++combine_paths(Rest).

java_reader(Port,Identity) ->
  receive
    {to_port,Data} ->
      Port!{self(), {command, Data}},
      java_reader(Port,Identity);
    {control,terminate_reader} ->
      ok;
    {_,{data,{eol,Message}}} ->
      io:format("~s~n",[Message]),
      java_reader(Port,Identity);
    {_,{data,{noeol,Message}}} ->
      io:format("~s~n",[Message]),
      java_reader(Port,Identity);
    Other ->
      format
	(warning,
	 "java_reader ~p got strange message~n  ~p~n",[Identity,Other]),
      java_reader(Port,Identity)
  end.

connectToNode(Node) ->
  connectToNode
    (Node,
     addTimeStamps(erlang:now(),milliSecondsToTimeStamp(Node#node.ping_retry))).

connectToNode(PreNode,KeepOnTryingUntil) ->
  NodeName = PreNode#node.node_name,
  SymbolicName = PreNode#node.symbolic_name,
  case net_adm:ping(NodeName) of
    pong ->
      java:format
	(debug,"~p: connected to Java node ~p~n",
	 [SymbolicName,NodeName]),
      {javaNode,NodeName}!{connect,PreNode#node.node_id,self()},
      connect_receive(NodeName,SymbolicName,PreNode,KeepOnTryingUntil);
    pang ->
      case compareTimes_ge(erlang:now(),KeepOnTryingUntil) of
	true -> 
	  format
	    (error,
	     "*** Error: ~p: failed trying to connect to Java node ~p~n",
	     [SymbolicName,NodeName]),
	  {error,timeout};
	false ->
	  timer:sleep(100),
	  connectToNode(PreNode,KeepOnTryingUntil)
      end
  end.

connect_receive(NodeName,SymbolicName,PreNode,KeepOnTryingUntil) ->
  receive
    {value,{connected,Pid,UnixPid}} when is_pid(Pid) ->
      java:format
	(debug,"~p (~p): got Java pid ~p~n",
	 [NodeName,SymbolicName,Pid]),
      Node = PreNode#node{node_pid=Pid,unix_pid=UnixPid},
      {ok,Node};
    {value,already_connected} ->
      %% Oops. We are talking to an old Java node...
      %% We should try to start another one...
      {error,already_connected};
    Other ->
      format
	(warning,
	 "*** ~p: Warning: got reply ~p instead of a pid "++
	   "when trying to connect to node ~p~n",
	 [SymbolicName,Other,{javaNode,NodeName}]),
      connect_receive(NodeName,SymbolicName,PreNode,KeepOnTryingUntil)
  after PreNode#node.connect_timeout -> 
      %% Failed to connect. We should try to start another node.
      {error,connect_timeout}
  end.

compareTimes_ge({M1,S1,Mic1}, {M2,S2,Mic2}) ->
  M1 > M2
    orelse (M1 =:= M2 andalso S1 > S2)
    orelse (M1 =:= M2 andalso S1 =:= S2 andalso Mic1 >= Mic2).

milliSecondsToTimeStamp(MilliSeconds) ->
  Seconds = MilliSeconds div 1000,
  MegaSeconds = Seconds div 1000000,
  {MegaSeconds, Seconds rem 1000000, MilliSeconds rem 1000 * 1000}.

addTimeStamps({M1,S1,Mic1},{M2,S2,Mic2}) ->
  Mic=Mic1+Mic2,
  MicRem = Mic rem 1000000,
  MicDiv = Mic div 1000000,
  S = S1+S2+MicDiv,
  SRem = S rem 1000000,
  SDiv = S div 1000000,
  M = M1+M2+SDiv,
  {M,SRem,MicRem}.

javaNodeName(Identity,Node) ->
  IdentityStr = integer_to_list(Identity),
  NodeStr = 
    case Node#node.node_node of
      void ->
	atom_to_list(node());
      _ -> 
	atom_to_list(Node#node.node_node)
    end,
  HostPart = string:substr(NodeStr,string:str(NodeStr,"@")),
  list_to_atom("javaNode_"++IdentityStr++HostPart).

%% @private
-spec javaCall(node_id(),atom(),any()) -> any().
javaCall(NodeId,Type,Msg) ->
  case node_lookup(NodeId) of
    {ok, Node} ->
      JavaMsg = create_msg(Type,Msg,Node),
      Node#node.node_pid!JavaMsg,
      Reply = wait_for_reply(Node),
      Reply;
    _ ->
      format(error,"javaCall: nodeId ~p not found~n",[NodeId]),
      format(error,"type: ~p message: ~p~n",[Type,Msg]),
      throw(javaCall)
  end.

create_msg(Type,Msg,Node) ->
  case msg_type(Type) of
    thread_msg -> 
      {Type,get_thread(Node),Msg,self()};
    _ ->
      {Type,Msg,self()}
  end.
    
msg_type(identity) -> non_thread_msg;
msg_type(reset) -> non_thread_msg;
msg_type(terminate) -> non_thread_msg;
msg_type(connect) -> non_thread_msg;
msg_type(define_invocation_handler) -> non_thread_msg;
msg_type(getConstructors) -> non_thread_msg;
msg_type(getClassLocation) -> non_thread_msg;
msg_type(getMethods) -> non_thread_msg;
msg_type(getClasses) -> non_thread_msg;
msg_type(getFields) -> non_thread_msg;
msg_type(getConstructor) -> non_thread_msg;
msg_type(getMethod) -> non_thread_msg;
msg_type(getField) -> non_thread_msg;
msg_type(objTypeCompat) -> non_thread_msg;
msg_type(createThread) -> non_thread_msg;
msg_type(stopThread) -> non_thread_msg;
msg_type(free) -> non_thread_msg;
msg_type(_) -> thread_msg.

wait_for_reply(Node) ->
  Timeout = get_timeout(Node),
  receive
    {'EXIT',_Pid,normal} ->
      wait_for_reply(Node);
    {value,Val} ->
      Val;
    _Exc={exception,ExceptionValue} ->
      case proplists:get_value(java_exception_as_value,Node#node.options,false) of
	true ->
	  {java_exception,ExceptionValue};
	false ->
	  throw_java_exception(ExceptionValue)
      end
%%    Other -> 
%%      io:format
%%	("~p(~p) at pid ~p~nstrange message ~p received~n",
%%	 [Node#node.symbolic_name,Node#node.node_id,self(),Other]),
%%      wait_for_reply(Node)
  after Timeout -> throw(java_timeout) 
  end.

throw_java_exception(ExceptionValue) ->
  throw({java_exception,ExceptionValue}).

create_thread(NodeId) ->
  javaCall(NodeId,createThread,0).

get_thread(Node) ->
  case ets:lookup(java_threads,{Node#node.node_id,self()}) of
    [{_,Thread}] -> 
      Thread;
    _ ->
      Thread = create_thread(Node#node.node_id),
      ets:insert(java_threads,{{Node#node.node_id,self()},Thread}),
      Thread
  end.

%% @private
%% @doc
%% An identity function for Java objects.
identity(NodeId,Value) ->
  javaCall(NodeId,identity,Value).

%% @doc
%% Calls the constructor of a Java class.
%% Returns an object reference.
%% <p>
%% Example: ``java:new(NodeId,'java.util.HashSet',[])'',
%% corresponding to the statement `new HashSet()'.
%% </p>
%% <p>
%% Due to the rules of Java method application (see explanation note in
%% module description)
%% it is possible that the correct constructor
%% for its arguments cannot be found. In that case,
%% `new/4' should be used intead.
%% </p>
-spec new(node_id(),class_name(),[value()]) -> object_ref().
new(NodeId,ClassName,Args) when is_list(Args) ->
  ?LOG("NodeId=~p ClassName=~p~n",[NodeId,ClassName]),
  Constructor = java_to_erlang:find_constructor(NodeId,ClassName,Args),
  javaCall(NodeId,call_constructor,{Constructor,list_to_tuple(Args)}).

%% @doc
%% Calls the constructor of a Java class, explicitely selecting
%% a particular constructor.
%% Returns an object reference.
%% <p>
%% Example: 
%%     ``java:new(NodeId,'java.lang.Integer',[int],[42])'',
%% corresponding to the statement
%% `new Integer(42)'.
%% </p>
-spec new(node_id(),class_name(),[type()],[value()]) -> object_ref().
new(NodeId,ClassName,ArgTypes,Args) when is_list(Args) ->
  ?LOG("NodeId=~p ClassName=~p~n",[NodeId,ClassName]),
  Constructor =
    java_to_erlang:find_constructor_with_type(NodeId,ClassName,ArgTypes),
  javaCall(NodeId,call_constructor,{Constructor,list_to_tuple(Args)}).

%% @doc
%% Calls a Java instance method.
%% Example: 
%%     ``java:call(Object,toString,[])'', 
%% corresponding to the call `Object.toString()'.
-spec call(object_ref(),method_name(),[value()]) -> value().
call(Object,Method,Args) when is_list(Args) ->
  ensure_non_null(Object),
  JavaMethod = java_to_erlang:find_method(Object,Method,Args),
  javaCall(node_id(Object),call_method,{Object,JavaMethod,list_to_tuple(Args)}).

%% @doc
%% Calls a Java instance method, explicitely
%% selecting a particular method, using the type argument to
%% distinguish between methods of the same arity.
-spec call(object_ref(),method_name(),[type()],[value()]) -> value().
call(Object,Method,ArgTypes,Args) when is_list(Args) ->
  ensure_non_null(Object),
  JavaMethod =
    java_to_erlang:find_method_with_type(Object,Method,ArgTypes),
  javaCall(node_id(Object),call_method,{Object,JavaMethod,list_to_tuple(Args)}).

%% @doc
%% Calls a Java static method (a class method).
%% Example:
%%     ``java:call_static(NodeId,'java.lang.Integer',reverseBytes,[22])'', 
%% corresponding to the call `Integer.reverseBytes(22)'.
-spec call_static(node_id(),class_name(),method_name(),[value()]) -> value().
call_static(NodeId,ClassName,Method,Args) when is_list(Args) ->
  JavaMethod =
    java_to_erlang:find_static_method(NodeId,ClassName,Method,Args),
  javaCall(NodeId,call_method,{null,JavaMethod,list_to_tuple(Args)}).

%% @doc
%% Calls a Java static method (a class method). Explicitely
%% selects which method to call using the types argument.
-spec call_static(node_id(),class_name(),method_name(),[type()],[value()]) -> value().
call_static(NodeId,ClassName,Method,ArgTypes,Args) when is_list(Args) ->
  JavaMethod =
    java_to_erlang:find_static_method_with_type
      (NodeId,ClassName,Method,ArgTypes),
  javaCall(NodeId,call_method,{null,JavaMethod,list_to_tuple(Args)}).

%% @doc
%% Retrieves the value of an instance attribute.
%% Example: 
%% ``java:get(Object,v)', corresponding to 'Object.v''.
-spec get(object_ref(), attribute_name()) -> value().
get(Object,Field) ->
  ensure_non_null(Object),
  JavaField = java_to_erlang:find_field(Object,Field),
  javaCall(node_id(Object),getFieldValue,{Object,JavaField,null}).

%% @doc
%% Retrieves the value of a class attribute.
%% Example: 
%% ``java:get_static(NodeId,'java.lang.Integer','SIZE')'', 
%% corresponding to `Integer.SIZE'.
-spec get_static(node_id(), class_name(), attribute_name()) -> value().
get_static(NodeId,ClassName,Field) ->
  JavaField = java_to_erlang:find_static_field(NodeId,ClassName,Field),
  javaCall(NodeId,getFieldValue,{null,JavaField,null}).

%% @doc
%% Modifies the value of an instance attribute.
-spec set(object_ref(), attribute_name(), value()) -> value().
set(Object,Field,Value) ->
  ensure_non_null(Object),
  JavaField = java_to_erlang:find_field(Object,Field),
  javaCall(node_id(Object),setFieldValue,{Object,JavaField,Value}).

%% @doc
%% Modifies the value of a static, i.e., class attribute.
-spec set_static(node_id(), class_name(), attribute_name(), value()) -> value().
set_static(NodeId,ClassName,Field,Value) ->
  JavaField = java_to_erlang:find_static_field(NodeId,ClassName,Field),
  javaCall(NodeId,setFieldValue,{null,JavaField,Value}).

%% @doc Initializes the Java interface library
%% providing default options.
%% It is called automatically by `start_node/0' and
%% `standard_node/1'. Calling `init/1' explicitely is
%% useful to customize the library when multiple
%% Java connections are used.
-spec init([option()]) -> boolean().
init(UserOptions) ->
  DefaultOptions = default_options(),
  Options = UserOptions++DefaultOptions,
  open_db(Options).

open_db() ->
  open_db(false,void).

open_db(Options) ->
  open_db(true,Options).

open_db(Init,Options) ->
  SelfPid = self(),
  case ets:info(java_nodes) of
    undefined ->
      spawn(fun () ->
		%%io:format("spawned db ~p~n",[self()]),
		try 
		  ets:new(java_nodes,[named_table,public]),
		  ets:insert(java_nodes,{java_node_counter,0}),
		  ets:new(java_classes,[named_table,public]),
		  ets:new(java_threads,[named_table,public]),
		  ets:new(java_objects,[named_table,public]),
		  wait_until_stable(),
		  if
		    Init ->
		      ets:insert(java_nodes,{options,Options});
		    true ->
		      ok
		  end,
		  SelfPid!{initialized,true},
		  wait_forever()
		catch _:_ ->
		    wait_until_stable(),
		    SelfPid!{initialized,false}
		    %%io:format("terminating db ~p~n",[self()])
		end
	    end),
      receive
	{initialized,DidInit} -> DidInit
      end;
    _ ->
      wait_until_stable(),
      false
  end.

wait_until_stable() ->
  case {ets:info(java_nodes),
	ets:info(java_classes),
	ets:info(java_threads),
	ets:info(java_objects)} of
    {Info1,Info2,Info3,Info4}
      when is_list(Info1), is_list(Info2), is_list(Info3), is_list(Info4) ->
      ok;
    _ ->
      timer:sleep(10),
      wait_until_stable()
  end.

wait_forever() ->
  receive _ -> wait_forever() end.
      
%% @doc
%% Returns a list with the default options.
-spec default_options() -> [option()].
default_options() ->
  OtpClassPath =
    case code:priv_dir(jinterface) of
      {error,_} -> [];
      OtpPath when is_list(OtpPath) ->
	[OtpPath++"/OtpErlang.jar"]
    end,
  JavaErlangClassPath =
    case code:priv_dir(java_erlang) of
      {error,_} -> [];
      JavaErlangPath when is_list(JavaErlangPath) ->
	[JavaErlangPath++"/JavaErlang.jar"]
    end,
  ClassPath = OtpClassPath++JavaErlangClassPath,
  JavaExecutable = 
    case os:find_executable("java") of
      false -> "java";
      Executable -> Executable
    end,
  ?LOG("Java classpath is ~p~n",[ClassPath]),
  [{java_class,"javaErlang.JavaErlang"},
   {java_classpath,ClassPath},
   {java_executable,JavaExecutable},
   {call_timeout,10000},
   {log_level,notice}].


%% @doc
%% Returns the version number of the JavaErlang library.
-spec version() -> string().
version() ->
  ?JAVA_ERLANG_VERSION.


%% @doc Returns the node where the object argument is located.
-spec node_id(object_ref()) -> node_id().
node_id({_,_,NodeId}) ->
  NodeId.

%% @doc
%% Returns the symbolic name of a Java node.
-spec symbolic_name(node_id()) -> string().
symbolic_name(NodeId) ->
  {ok,Node} = node_lookup(NodeId),
  Node#node.symbolic_name.

%% @doc
%% Returns the set of active Java nodes.
-spec nodes() -> [node_id()].
nodes() ->
  case ets:info(java_nodes) of
    undefined -> [];
    _ ->
      lists:map
	(fun ({NodeId,_Node}) when is_integer(NodeId) -> NodeId end,
	 ets:tab2list(java_nodes))
  end.

%% @doc
%% Resets the state of a Java node, i.e., 
%% the object proxy is reset.
%% This operation will cause all Java object references
%% existing to become invalid (i.e., not referring to
%% any Java object), but references to Java methods, constructors
%% or fields are not affected. In addition all threads created are
%% eventually stopped, and a new thread created to service future
%% calls. Note that the function call may return before all threads
%% have stopped.
-spec reset(node_id()) -> any().
reset(NodeId) ->
  %% Threads are removed, so we have to clean up the Erlang thread table
  remove_thread_mappings(NodeId),
  remove_object_mappings(NodeId),
  javaCall(NodeId,reset,void).

%% @doc
%% Shuts down and terminates the connection to a Java node.
-spec terminate(node_id()) -> any().
terminate(NodeId) ->
  javaCall(NodeId,terminate,void),
  remove_thread_mappings(NodeId),
  remove_object_mappings(NodeId),
  remove_class_mappings(NodeId),
  {ok,Node} = node_lookup(NodeId),
  Node#node.port_pid!{control,terminate_reader},
  ets:delete(java_nodes,NodeId).

%% @doc
%% Shuts down and terminates the connection to all known Java nodes.
-spec terminate_all() -> any().
terminate_all() ->
  case ets:info(java_nodes) of
    undefined -> ok;
    _ ->
      lists:foreach
	(fun ({NodeId,_Node}) ->
	     javaCall(NodeId,terminate,void),
	     {ok,Node} = node_lookup(NodeId),
	     Node#node.port_pid!{control,terminate_reader};
	     (_) -> ok
	 end, ets:tab2list(java_nodes)),
      ets:delete(java_nodes),
      ets:delete(java_classes),
      ets:delete(java_objects),
      ets:delete(java_threads)
  end.

%% @doc
%% Brutally shuts down and terminates the connection to a Java node.
%% Does not send a termination message to the Java node, instead it
%% attempts to kill the Unix process corresponding to the Java runtime system
%% of the node. This will obviously only work under Unix/Linux.
-spec brutally_terminate(node_id()) -> any().
brutally_terminate(NodeId) ->
  {ok,Node} = node_lookup(NodeId),
  remove_thread_mappings(NodeId),
  remove_object_mappings(NodeId),
  remove_class_mappings(NodeId),
  ets:delete(java_nodes,NodeId),
  spawn(Node#node.node_node,?MODULE,terminate_brutally,[Node]).

%% @private
terminate_brutally(Node) ->
  case runs_on_windows() of
    true ->
      java:format
	(error,
	 "*** Error: ~p: brutally_terminate not supported under windows~n",
	 [Node#node.symbolic_name]),
      throw(nyi);
    _ -> ok
  end,
  Node#node.port_pid!{control,terminate_reader},
  os:cmd(io_lib:format("kill -9 ~p",[Node#node.unix_pid])).

%% @doc
%% Recreates a possibly dead node. Obviously any ongoing computations,
%% object bindings, and so on are forgotten, but the classpaths
%% and other node options are restored.
-spec recreate_node(node_id()) -> {ok,node_id()} | {error,any()}.

recreate_node(NodeId) ->
  {ok,Node} = node_lookup(NodeId),
  PreNode = Node#node{num_start_tries=0},
  spawn_java(PreNode,get_java_node_id()).

%% @doc
%% Brutally shuts down and attempts to terminate 
remove_thread_mappings(NodeId) ->
  lists:foreach
    (fun ({Key={NodeIdKey,_},_}) ->
	 if NodeId==NodeIdKey -> ets:delete(java_threads,Key);
	    true -> ok
	 end
     end, ets:tab2list(java_threads)).

remove_class_mappings(NodeId) ->
  Classes = ets:tab2list(java_classes),
  lists:foreach
    (fun ({Key,_Value}) ->
	 case Key of
	   {NodeId,_} -> ets:delete(java_classes,Key);
	   _ -> ok
         end
     end, Classes).

remove_object_mappings(NodeId) ->
  lists:foreach
    (fun ({Key={_,_,NodeIdKey},_}) ->
	 if NodeId==NodeIdKey -> ets:delete(java_objects,Key);
	    true -> ok
	 end
     end, ets:tab2list(java_objects)).

%% @doc
%% Lets Java know that an object can be freed.
-spec free(object_ref()) -> any().
free(Object) ->
  javaCall(node_id(Object),free,Object).	      

%% @doc Sets the timeout value for Java calls.
%% Calls to Java from the current Erlang process will henceforth
%% fail after Timeout seconds (or never is the argument is
%% the atom infinity).
%% Implementation note: this function stores data in the Erlang 
%% process dictionary.
-spec set_timeout(integer() | infinity) -> any().
set_timeout(Timeout) ->
  case Timeout of
    _ when is_integer(Timeout), Timeout>=0 -> ok;
    infinity -> ok;
    _ -> throw(badarg)
  end,
  set_value(timeout,Timeout).

get_timeout(Node) ->
  get_value(timeout,Node#node.call_timeout).

set_value(ValueName,Value) ->
  PropList =
    case erlang:get({javaErlangOptions,self()}) of
      undefined ->
	[];
      Other ->
	proplists:delete(ValueName,Other)
    end,
  put({javaErlangOptions,self()},[{ValueName,Value}|PropList]).

get_value(ValueName,Default) ->
  case get({javaErlangOptions,self()}) of
    PropList when is_list(PropList) ->
      proplists:get_value(ValueName,PropList,Default);
    _ ->
      Default
  end.



%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%% 

%% @doc
%% Returns true if its argument is a Java object reference, false otherwise.
-spec is_object_ref(any()) -> boolean().
is_object_ref({object,_,_}) ->
  true;
is_object_ref({executable,_,_}) ->
  true;
is_object_ref({thread,_,_}) ->
  true;
is_object_ref(_) ->
  false.


%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%% 

%% @doc
%% Returns the elements of the (one-dimensional) array object argument
%% as an Erlang list of objects.
-spec array_to_list(object_ref()) -> [value()].
array_to_list(ArrayObj) ->
  javaCall(node_id(ArrayObj),array_to_list,ArrayObj).

%% @doc
%% Creates a one-dimensional Java array populated with the elements
%% from the Erlang list argument, using the type specification
%% as an element recipe. Example:
%% ``java:list_to_array(NodeId,"Hello World!",char).''
-spec list_to_array(node_id(),[value()],type()) -> object_ref().
list_to_array(NodeId,List,Type) when is_list(List) ->
  javaCall(NodeId,list_to_array,{Type,list_to_tuple(List)}).

%% @doc
%% Returns the elements of the Java String as an Erlang list.
-spec string_to_list(object_ref()) -> [char()].
string_to_list(String) ->
  Bytes = java:call(String,getBytes,[]),
  array_to_list(Bytes).

%% @doc 
%% Converts the Erlang string argument to a Java string.
%% This function is for convenience only; it is implementable using
%% the rest of the Java API.
-spec list_to_string(node_id(),string()) -> object_ref().
list_to_string(NodeId,List) when is_list(List) ->
  java:new(NodeId,'java.lang.String',[List]).

%% @doc Widens or narrows a number.
-spec convert(node_id(),number_type(),java_number()) -> java_number().
convert(NodeId,Class,Number) when is_number(Number), is_atom(Class) ->
  javaCall(NodeId,convert,{Class,Number}).

%% @doc
%% Returns true if the first parameter (a Java object) is an instant
%% of the class named by the second parameter.
%% This function is for convenience only; it is implementable using
%% the rest of the Java API.
-spec instanceof(object_ref(),class_name()) -> boolean().
instanceof(Obj,ClassName) when is_list(ClassName) ->
  instanceof(Obj,list_to_atom(ClassName));
instanceof(Object,ClassName) when is_atom(ClassName) ->
  javaCall(node_id(Object),instof,{Object,ClassName}).

%% @doc Convenience method for determining subype relationship.
%% Returns true if the first argument is a subtype of the second.
-spec is_subtype(node_id(),class_name(),class_name()) -> boolean().
is_subtype(NodeId,Class1,Class2) when is_atom(Class1), is_atom(Class2) ->
  javaCall(NodeId,is_subtype,{Class1,Class2}).

%% @doc
%% Returns the classname (as returned by the method getName() in
%% java.lang.Class)
%% of Java object parameter.
%% This function is for convenience only; it is implementable using
%% the rest of the Java API.
-spec getClassName(object_ref()) -> class_name().
getClassName(Object) ->
  getClassName(node_id(Object),Object).
-spec getClassName(node_id(),object_ref()) -> class_name().
getClassName(NodeId,Obj) ->
  javaCall(NodeId,getClassName,Obj).

%% @doc
%% Returns the simple classname (as returned by the method getSimplename() in
%% java.lang.Class)
%% of Java object parameter.
%% This function is for convenience only; it is implementable using
%% the rest of the Java API.
-spec getSimpleClassName(object_ref()) -> class_name().
getSimpleClassName(Object) ->
  getSimpleClassName(node_id(Object),Object).
-spec getSimpleClassName(node_id(),object_ref()) -> class_name().
getSimpleClassName(NodeId,Obj) ->
  javaCall(NodeId,getSimpleClassName,Obj).

%% @doc
%% Prints the Java stacktrace on the standard error file error descriptor
%% that resulted in the throwable object argument.
%% This function is for convenience only; it is implementable using
%% the rest of the Java API.
-spec print_stacktrace(object_ref()) -> any().
print_stacktrace(Exception) ->
  Err = get_static(node_id(Exception),'java.lang.System',err),
  call(Exception,printStackTrace,[Err]).

%% @doc
%% Returns the Java stacktrace as an Erlang list.
%% This function is for convenience only; it is implementable using
%% the rest of the Java API.
-spec get_stacktrace(object_ref()) -> list().
get_stacktrace(Exception) ->
  StringWriter = new(node_id(Exception),'java.io.StringWriter',[]),
  PrintWriter = new(node_id(Exception),'java.io.PrintWriter',[StringWriter]),
  call(Exception,printStackTrace,[PrintWriter]),
  string_to_list(call(StringWriter,toString,[])).


%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%% 

%% @private
-spec acquire_class(node_id(),class_name()) -> #class{}.
acquire_class(NodeId,ClassName) when is_atom(ClassName) ->
  ?LOG("acquire_class(~p,~p)~n",[NodeId,ClassName]),
  acquire_class_int(NodeId,ClassName).

acquire_class_int(NodeId,ClassName) ->
  case class_lookup(NodeId,ClassName) of
    {ok,Class} ->
      Class;
    _ ->
      case get_load_permission(NodeId,ClassName) of
	ok ->
	  try java_to_erlang:compute_class(NodeId,ClassName) of
	    Class ->
	      ets:delete(java_classes,{loading,NodeId,ClassName}),
	      class_store(NodeId,ClassName,Class)
	  catch ExceptionClass:Reason ->
	      ets:delete(java_classes,{loading,NodeId,ClassName}),
	      erlang:raise(ExceptionClass,Reason,erlang:get_stacktrace())
	  end
      end
  end.

%% Since classes can be loaded from multiple processes simultaneously
%% we have to serialize such attempts (to prevent getting purge errors
%% for instance).
get_load_permission(NodeId,ClassName) ->
  case ets:insert_new(java_classes,{{loading,NodeId,ClassName},self()}) of
    true ->
      ok;
    false ->
      timer:sleep(10),
      get_load_permission(NodeId,ClassName)
  end.

class_lookup(NodeId,ClassName) when is_atom(ClassName) ->
  Key = {NodeId,ClassName},
  case ets:lookup(java_classes,Key) of
    [{_,Class}] ->
      {ok,Class};
    _ ->
      false
  end.

class_store(NodeId,ClassName,Class) when is_atom(ClassName) ->
  java:format(debug,"Storing class info for class ~p~n",[ClassName]),
  ets:insert(java_classes,{{NodeId,ClassName},Class}),
  Class.

%% @private
node_lookup(NodeId) ->
  case ets:lookup(java_nodes,NodeId) of
    [{_,Node}] ->
      {ok,Node};
    _ ->
      format(error,"node_lookup(~p) failed??~n",[NodeId]),
      false
  end.

node_store(Node) ->
  ets:insert(java_nodes,{Node#node.node_id,Node}).
  
%% @private
find_class(Object) ->
  case ets:lookup(java_objects,Object) of
    [{_,Class}] -> Class;
    _ ->
      ClassName = getClassName(node_id(Object),Object),
      Class = acquire_class_int(node_id(Object),ClassName),
      ets:insert(java_objects,{Object,Class}),
      Class
  end.

firstComponent(Atom) when is_atom(Atom) ->
  list_to_atom(firstComponent(atom_to_list(Atom)));
firstComponent(Atom) when is_list(Atom) ->
  case string:chr(Atom,$.) of
    0 -> Atom;
    N -> string:substr(Atom,1,N-1)
  end.

%% @private
finalComponent(Atom) when is_atom(Atom) ->
  list_to_atom(finalComponent(atom_to_list(Atom)));
finalComponent(Atom) when is_list(Atom) ->
  case string:rchr(Atom,$.) of
    0 -> Atom;
    N -> string:substr(Atom,N+1)
  end.

ensure_non_null(Object) ->
  if
    Object==null ->
      format(warning,"~n*** Warning: null object~n",[]),
      throw(badarg);
    true -> ok
  end.

%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%% 


runs_on_windows() ->
  case os:type() of
    {win32,_} ->
      true;
    {win64,_} ->
      true;
    _ -> 
      false
  end.

%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%


%% Rudimentary logging support; in the future we should probably use
%% a standard logger

get_options() ->
  case ets:info(java_nodes) of
    undefined -> default_options();
    _ -> 
      case ets:lookup(java_nodes,options) of
	[{_,Options}] -> Options;
	[] -> default_options()
      end
  end.

%% @doc
%% Determines how much debugging information is displayed.
%%
-spec set_loglevel(Level::loglevel()) -> any().
set_loglevel(Level) ->
  user_level(Level),
  case init([{log_level,Level}]) of
    true -> ok;
    false -> 
      Options = get_options(),
      ets:insert(java_nodes,{options,[{log_level,Level}|Options]})
  end.

get_loglevel() ->
  proplists:get_value(log_level,get_options()).

%% @private
format(Level,Message) ->
  level(Level),
  case permit_output(get_loglevel(),Level) of
    true -> io:format(Message);
    _ -> ok
  end.

%% @private
format(Level,Format,Message) ->
  level(Level),
  case permit_output(get_loglevel(),Level) of
    true -> io:format(Format,Message);
    _ -> ok
  end.

permit_output(LevelInterest,LevelOutput) ->
  user_level(LevelInterest) >= level(LevelOutput).

user_level(none) -> -1;
user_level(all) -> 100;
user_level(Other) -> level(Other).

level(emergency) -> 0;
level(alert) -> 1;
level(critical) -> 2;
level(error) -> 3;
level(warning) -> 4;
level(notice) -> 5;
level(info) -> 6;
level(debug) -> 7;
level(_) -> throw(badarg).

    

