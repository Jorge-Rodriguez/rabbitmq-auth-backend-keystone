%% The contents of this file are subject to the Mozilla Public License
%% Version 1.1 (the "License"); you may not use this file except in
%% compliance with the License. You may obtain a copy of the License
%% at http://www.mozilla.org/MPL/
%%
%% Software distributed under the License is distributed on an "AS IS"
%% basis, WITHOUT WARRANTY OF ANY KIND, either express or implied. See
%% the License for the specific language governing rights and
%% limitations under the License.
%%
%% The Original Code is RabbitMQ.
%%
%% The Initial Developer of the Original Code is VMware, Inc.
%% Copyright (c) 2007-2013 VMware, Inc.  All rights reserved.
%%

%% Modified to authenticate against OpenStack Keystone (BRC 01-Jul-2013)

-module(rabbit_auth_backend_keystone).
-include("rabbit.hrl").

-behaviour(rabbit_authn_backend).
-behaviour(rabbit_authz_backend).

-export([description/0]).
-export([user_login_authentication/2, user_login_authorization/1,
         check_vhost_access/3, check_resource_access/3]).

-export([add_user/2, delete_user/1, change_password/2, set_tags/2,
         list_users/0, user_info_keys/0, lookup_user/1, clear_password/1]).
-export([make_salt/0, check_password/2, change_password_hash/2,
         hash_password/1]).
-export([set_permissions/5, clear_permissions/2,
         list_permissions/0, list_vhost_permissions/1, list_user_permissions/1,
         list_user_vhost_permissions/2, perms_info_keys/0,
         vhost_perms_info_keys/0, user_perms_info_keys/0,
         user_vhost_perms_info_keys/0]).

-ifdef(use_specs).

-type(regexp() :: binary()).

-spec(add_user/2 :: (rabbit_types:username(), rabbit_types:password()) -> 'ok').
-spec(delete_user/1 :: (rabbit_types:username()) -> 'ok').
-spec(change_password/2 :: (rabbit_types:username(), rabbit_types:password())
                           -> 'ok').
-spec(clear_password/1 :: (rabbit_types:username()) -> 'ok').
-spec(make_salt/0 :: () -> binary()).
-spec(check_password/2 :: (rabbit_types:password(),
                           rabbit_types:password_hash()) -> boolean()).
-spec(change_password_hash/2 :: (rabbit_types:username(),
                                 rabbit_types:password_hash()) -> 'ok').
-spec(hash_password/1 :: (rabbit_types:password())
                         -> rabbit_types:password_hash()).
-spec(set_tags/2 :: (rabbit_types:username(), [atom()]) -> 'ok').
-spec(list_users/0 :: () -> [rabbit_types:infos()]).
-spec(user_info_keys/0 :: () -> rabbit_types:info_keys()).
-spec(lookup_user/1 :: (rabbit_types:username())
                       -> rabbit_types:ok(rabbit_types:internal_user())
                              | rabbit_types:error('not_found')).
-spec(set_permissions/5 ::(rabbit_types:username(), rabbit_types:vhost(),
                           regexp(), regexp(), regexp()) -> 'ok').
-spec(clear_permissions/2 :: (rabbit_types:username(), rabbit_types:vhost())
                             -> 'ok').
-spec(list_permissions/0 :: () -> [rabbit_types:infos()]).
-spec(list_vhost_permissions/1 ::
        (rabbit_types:vhost()) -> [rabbit_types:infos()]).
-spec(list_user_permissions/1 ::
        (rabbit_types:username()) -> [rabbit_types:infos()]).
-spec(list_user_vhost_permissions/2 ::
        (rabbit_types:username(), rabbit_types:vhost())
        -> [rabbit_types:infos()]).
-spec(perms_info_keys/0 :: () -> rabbit_types:info_keys()).
-spec(vhost_perms_info_keys/0 :: () -> rabbit_types:info_keys()).
-spec(user_perms_info_keys/0 :: () -> rabbit_types:info_keys()).
-spec(user_vhost_perms_info_keys/0 :: () -> rabbit_types:info_keys()).
-endif.

%%----------------------------------------------------------------------------

-define(PERMS_INFO_KEYS, [configure, write, read]).
-define(USER_INFO_KEYS, [user, tags]).

%% httpc seems to get racy when using HTTP 1.1
-define(HTTPC_OPTS, [{version, "HTTP/1.0"}]).


%% Implementation of rabbit_auth_backend

split_username(Username, N) ->
    case string:str(Username, "\\") of
        0 ->
            [list_to_binary(Username)];
        Pos ->
            [list_to_binary(string:substr(Username, 1, Pos - 1)) | split_username(string:substr(Username, Pos + 1), N - 1)]
    end.

description() ->
    [{name, <<"Keystone">>},
     {description, <<"OpenStack Keystone authentication">>}].

user_login_authentication(Username, [{password, Password}]) ->
    P = binary_to_list(Password),
    [List, RabbitUsername] = case split_username(binary_to_list(Username), 2) of
        [UserName] ->
            U = binary_to_list(UserName),
            [io_lib:format("{\"auth\":{\"identity\":{\"methods\":[\"password\"],\"password\":{\"user\":{\"name\":\"~s\",\"password\":\"~s\"}}}}}", [U, P]), UserName];
        [DomainId, UserName] ->
            D = binary_to_list(DomainId),
            U = binary_to_list(UserName),
            [io_lib:format("{\"auth\":{\"identity\":{\"methods\":[\"password\"],\"password\":{\"user\":{\"name\":\"~s\",\"password\":\"~s\"}}},\"scope\":{\"domain\":{\"id\":\"~s\"}}}}",
                            [U, P, D]), UserName]
    end,

    Data = lists:flatten(List),
    {ok, Path} = application:get_env(rabbitmq_auth_backend_keystone, user_path),

    case httpc:request(post, {Path, [], "application/json", Data}, [], []) of
        {ok, {{_Version, 401, _ReasonPhrase}, _Headers, _Body}} -> {refused, "Denied by Keystone plugin", []};
        {ok, {{_Version, 201, _ReasonPhrase}, _Headers, _Body}} ->
            case lookup_user(RabbitUsername) of
                {ok, User} ->
                     {ok, #auth_user{username     = RabbitUsername,
                                     tags         = User#internal_user.tags,
                                     impl         = none}};
                {error, not_found} ->
                    {refused, "User not defined internally", []}
            end;
        Other ->
            {error, {bad_response, Other}}
    end;

user_login_authentication(Username, AuthProps) ->
    exit({unknown_auth_props, Username, AuthProps}).


user_login_authorization(Username) ->
    case user_login_authentication(Username, []) of
        {ok, #auth_user{impl = Impl}} -> {ok, Impl};
        Else                          -> Else
    end.

check_vhost_access(#auth_user{username = Username}, VHostPath, _Sock) ->
    case mnesia:dirty_read({rabbit_user_permission,
                            #user_vhost{username     = Username,
                                        virtual_host = VHostPath}}) of
        []   -> false;
        [_R] -> true
    end.

check_resource_access(#auth_user{username = Username},
                      #resource{virtual_host = VHostPath, name = Name},
                      Permission) ->
    case mnesia:dirty_read({rabbit_user_permission,
                            #user_vhost{username     = Username,
                                        virtual_host = VHostPath}}) of
        [] ->
            false;
        [#user_permission{permission = P}] ->
            PermRegexp = case element(permission_index(Permission), P) of
                             %% <<"^$">> breaks Emacs' erlang mode
                             <<"">> -> <<$^, $$>>;
                             RE     -> RE
                         end,
            case re:run(Name, PermRegexp, [{capture, none}]) of
                match    -> true;
                nomatch  -> false
            end
    end.

permission_index(configure) -> #permission.configure;
permission_index(write)     -> #permission.write;
permission_index(read)      -> #permission.read.

%%----------------------------------------------------------------------------
%% Manipulation of the user database

add_user(Username, Password) ->
    rabbit_log:info("Creating user '~s'~n", [Username]),
    R = rabbit_misc:execute_mnesia_transaction(
          fun () ->
                  case mnesia:wread({rabbit_user, Username}) of
                      [] ->
                          ok = mnesia:write(
                                 rabbit_user,
                                 #internal_user{username = Username,
                                                password_hash =
                                                    hash_password(Password),
                                                tags = []},
                                 write);
                      _ ->
                          mnesia:abort({user_already_exists, Username})
                  end
          end),
    R.

delete_user(Username) ->
    rabbit_log:info("Deleting user '~s'~n", [Username]),
    R = rabbit_misc:execute_mnesia_transaction(
          rabbit_misc:with_user(
            Username,
            fun () ->
                    ok = mnesia:delete({rabbit_user, Username}),
                    [ok = mnesia:delete_object(
                            rabbit_user_permission, R, write) ||
                        R <- mnesia:match_object(
                               rabbit_user_permission,
                               #user_permission{user_vhost = #user_vhost{
                                                  username = Username,
                                                  virtual_host = '_'},
                                                permission = '_'},
                               write)],
                    ok
            end)),
    R.

change_password(Username, Password) ->
    rabbit_log:info("Changing password for '~s'~n", [Username]),
    change_password_hash(Username, hash_password(Password)).

clear_password(Username) ->
    rabbit_log:info("Clearing password for '~s'~n", [Username]),
    change_password_hash(Username, <<"">>).

change_password_hash(Username, PasswordHash) ->
    R = update_user(Username, fun(User) ->
                                      User#internal_user{
                                        password_hash = PasswordHash }
                              end),
    R.

hash_password(Cleartext) ->
    Salt = make_salt(),
    Hash = salted_md5(Salt, Cleartext),
    <<Salt/binary, Hash/binary>>.

check_password(Cleartext, <<Salt:4/binary, Hash/binary>>) ->
    Hash =:= salted_md5(Salt, Cleartext);
check_password(_Cleartext, _Any) ->
    false.

make_salt() ->
    {A1,A2,A3} = now(),
    random:seed(A1, A2, A3),
    Salt = random:uniform(16#ffffffff),
    <<Salt:32>>.

salted_md5(Salt, Cleartext) ->
    Salted = <<Salt/binary, Cleartext/binary>>,
    erlang:md5(Salted).

set_tags(Username, Tags) ->
    rabbit_log:info("Setting user tags for user '~s' to ~p~n", [Username, Tags]),
    R = update_user(Username, fun(User) ->
                                      User#internal_user{tags = Tags}
                              end),
    R.

update_user(Username, Fun) ->
    rabbit_misc:execute_mnesia_transaction(
      rabbit_misc:with_user(
        Username,
        fun () ->
                {ok, User} = lookup_user(Username),
                ok = mnesia:write(rabbit_user, Fun(User), write)
        end)).

list_users() ->
    [[{user, Username}, {tags, Tags}] ||
        #internal_user{username = Username, tags = Tags} <-
            mnesia:dirty_match_object(rabbit_user, #internal_user{_ = '_'})].

user_info_keys() -> ?USER_INFO_KEYS.

lookup_user(Username) ->
    rabbit_misc:dirty_read({rabbit_user, Username}).

validate_regexp(RegexpBin) ->
    Regexp = binary_to_list(RegexpBin),
    case re:compile(Regexp) of
        {ok, _}         -> ok;
        {error, Reason} -> throw({error, {invalid_regexp, Regexp, Reason}})
    end.

set_permissions(Username, VHostPath, ConfigurePerm, WritePerm, ReadPerm) ->
    rabbit_log:info("Setting permissions for '~s' in '~s' to '~s', '~s', '~s'~n",
                    [Username, VHostPath, ConfigurePerm, WritePerm, ReadPerm]),
    lists:map(fun validate_regexp/1, [ConfigurePerm, WritePerm, ReadPerm]),
    rabbit_misc:execute_mnesia_transaction(
      rabbit_misc:with_user_and_vhost(
        Username, VHostPath,
        fun () -> ok = mnesia:write(
                         rabbit_user_permission,
                         #user_permission{user_vhost = #user_vhost{
                                            username     = Username,
                                            virtual_host = VHostPath},
                                          permission = #permission{
                                            configure = ConfigurePerm,
                                            write     = WritePerm,
                                            read      = ReadPerm}},
                         write)
        end)).


clear_permissions(Username, VHostPath) ->
    rabbit_misc:execute_mnesia_transaction(
      rabbit_misc:with_user_and_vhost(
        Username, VHostPath,
        fun () ->
                ok = mnesia:delete({rabbit_user_permission,
                                    #user_vhost{username     = Username,
                                                virtual_host = VHostPath}})
        end)).

perms_info_keys()            -> [user, vhost | ?PERMS_INFO_KEYS].
vhost_perms_info_keys()      -> [user | ?PERMS_INFO_KEYS].
user_perms_info_keys()       -> [vhost | ?PERMS_INFO_KEYS].
user_vhost_perms_info_keys() -> ?PERMS_INFO_KEYS.

list_permissions() ->
    list_permissions(perms_info_keys(), match_user_vhost('_', '_')).

list_vhost_permissions(VHostPath) ->
    list_permissions(
      vhost_perms_info_keys(),
      rabbit_vhost:with(VHostPath, match_user_vhost('_', VHostPath))).

list_user_permissions(Username) ->
    list_permissions(
      user_perms_info_keys(),
      rabbit_misc:with_user(Username, match_user_vhost(Username, '_'))).

list_user_vhost_permissions(Username, VHostPath) ->
    list_permissions(
      user_vhost_perms_info_keys(),
      rabbit_misc:with_user_and_vhost(
        Username, VHostPath, match_user_vhost(Username, VHostPath))).

filter_props(Keys, Props) -> [T || T = {K, _} <- Props, lists:member(K, Keys)].

list_permissions(Keys, QueryThunk) ->
    [filter_props(Keys, [{user,      Username},
                         {vhost,     VHostPath},
                         {configure, ConfigurePerm},
                         {write,     WritePerm},
                         {read,      ReadPerm}]) ||
        #user_permission{user_vhost = #user_vhost{username     = Username,
                                                  virtual_host = VHostPath},
                         permission = #permission{ configure = ConfigurePerm,
                                                   write     = WritePerm,
                                                   read      = ReadPerm}} <-
            %% TODO: use dirty ops instead
            rabbit_misc:execute_mnesia_transaction(QueryThunk)].

match_user_vhost(Username, VHostPath) ->
    fun () -> mnesia:match_object(
                rabbit_user_permission,
                #user_permission{user_vhost = #user_vhost{
                                   username     = Username,
                                   virtual_host = VHostPath},
                                 permission = '_'},
                read)
    end.
