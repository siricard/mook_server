defmodule MookServer.Accounts.Session do
  @moduledoc """
  This resource is intentionally non-persistent. It exposes session-oriented
  generic actions while delegating user persistence and token mechanics to the
  existing `User` and `Token` AshAuthentication resources.
  """

  use Ash.Resource,
    otp_app: :mook_server,
    domain: MookServer.Accounts,
    data_layer: Ash.DataLayer.Simple

  require Logger

  alias Ash.Query
  alias AshAuthentication.{Info, Jwt, Strategy, TokenResource}
  alias MookServer.Accounts.User
  alias MookServer.Repo

  @otp_app :mook_server
  @bootstrap_lock_key 1_001_011
  @refresh_purpose "refresh"
  @known_errors %{
    "authentication_failed" => :authentication_failed,
    "bootstrap_unavailable" => :bootstrap_unavailable,
    "invalid_bootstrap_request" => :invalid_bootstrap_request,
    "invalid_credentials" => :invalid_credentials,
    "invalid_refresh_token" => :invalid_refresh_token,
    "invalid_request" => :invalid_request,
    "invalid_token" => :invalid_token,
    "token_generation_failed" => :token_generation_failed,
    "token_revocation_failed" => :token_revocation_failed
  }

  code_interface do
    define :run_bootstrap,
      action: :bootstrap,
      args: [:params],
      default_options: [authorize?: false]

    define :run_login, action: :login, args: [:params], default_options: [authorize?: false]

    define :run_refresh,
      action: :refresh,
      args: [:refresh_token],
      default_options: [authorize?: false]

    define :run_logout,
      action: :logout,
      args: [{:optional, :access_token}, {:optional, :refresh_token}],
      default_options: [authorize?: false]
  end

  actions do
    action :bootstrap, :map do
      description "Bootstrap the first local account and issue a desktop session."
      argument :params, :map, allow_nil?: false

      run fn input, _context ->
        input.arguments.params
        |> normalize_params()
        |> bootstrap_local_account()
      end
    end

    action :login, :map do
      description "Sign in with a password and issue a desktop session."
      argument :params, :map, allow_nil?: false

      run fn input, _context ->
        input.arguments.params
        |> normalize_params()
        |> sign_in_with_password()
      end
    end

    action :refresh, :map do
      description "Rotate a refresh token and issue a new desktop session."

      argument :refresh_token, :string do
        allow_nil? false
        sensitive? true
      end

      run fn input, _context ->
        refresh_session(input.arguments.refresh_token)
      end
    end

    action :logout, :map do
      description "Revoke the provided desktop access and/or refresh tokens."

      argument :access_token, :string do
        allow_nil? true
        sensitive? true
      end

      argument :refresh_token, :string do
        allow_nil? true
        sensitive? true
      end

      run fn input, _context ->
        logout_session(input.arguments.access_token, input.arguments.refresh_token)
      end
    end
  end

  def bootstrap(params, opts \\ []) do
    params
    |> run_bootstrap(opts)
    |> normalize_action_result(:bootstrap)
  end

  def login(params, opts \\ []) do
    params
    |> run_login(opts)
    |> normalize_action_result(:login)
  end

  def refresh(refresh_token, opts \\ []) do
    refresh_token
    |> run_refresh(opts)
    |> normalize_action_result(:refresh)
  end

  def logout(access_token, refresh_token, opts \\ []) do
    access_token
    |> run_logout(refresh_token, opts)
    |> normalize_action_result(:logout)
  end

  defp normalize_action_result({:ok, payload}, _action), do: {:ok, payload}

  defp normalize_action_result({:error, %Ash.Error.Invalid{}}, :bootstrap),
    do: {:error, :invalid_bootstrap_request}

  defp normalize_action_result({:error, %Ash.Error.Invalid{}}, _action),
    do: {:error, :invalid_request}

  defp normalize_action_result({:error, %Ash.Error.Unknown{} = error}, action) do
    case unknown_error_reason(error) do
      nil -> normalize_unexpected_error(action, error)
      reason -> {:error, reason}
    end
  end

  defp normalize_action_result({:error, reason}, _action), do: {:error, reason}

  defp normalize_unexpected_error(action, error) do
    Logger.error("Accounts.Session #{action} returned an unexpected Ash error: #{inspect(error)}")
    {:error, :authentication_failed}
  end

  defp unknown_error_reason(%Ash.Error.Unknown{errors: errors}) do
    Enum.find_value(errors, fn
      %{error: "unknown error: :" <> reason} -> Map.get(@known_errors, reason)
      _ -> nil
    end)
  end

  defp normalize_params(params) when is_map(params) do
    Map.new(params, fn
      {key, value} when is_atom(key) -> {Atom.to_string(key), value}
      pair -> pair
    end)
  end

  defp normalize_params(_params), do: %{}

  defp bootstrap_local_account(%{
         "email" => email,
         "password" => password,
         "password_confirmation" => password_confirmation
       })
       when is_binary(email) and is_binary(password) and is_binary(password_confirmation) do
    params = %{
      "email" => email,
      "password" => password,
      "password_confirmation" => password_confirmation
    }

    with {:ok, {user, notifications}} <-
           Repo.transaction(fn ->
             with :ok <- acquire_bootstrap_lock(),
                  :ok <- ensure_bootstrap_available(),
                  {:ok, user, notifications} <- create_bootstrap_user(params) do
               {user, notifications}
             else
               {:error, reason} -> Repo.rollback(reason)
             end
           end),
         [] <- Ash.Notifier.notify(notifications),
         {:ok, payload} <- issue_session(user) do
      {:ok, payload}
    else
      {:error, :invalid_bootstrap_request} ->
        {:error, :invalid_bootstrap_request}

      {:error, :bootstrap_unavailable} ->
        {:error, :bootstrap_unavailable}

      {:error, reason} ->
        Logger.error("Accounts.Session bootstrap failed unexpectedly: #{inspect(reason)}")
        {:error, :authentication_failed}

      unsent_notifications when is_list(unsent_notifications) ->
        Logger.error(
          "Accounts.Session bootstrap left unsent notifications: #{inspect(unsent_notifications)}"
        )

        {:error, :authentication_failed}
    end
  end

  defp bootstrap_local_account(_), do: {:error, :invalid_bootstrap_request}

  defp sign_in_with_password(%{"email" => email, "password" => password})
       when is_binary(email) and is_binary(password) do
    strategy = Info.strategy!(User, :password)

    case Strategy.action(strategy, :sign_in, %{"email" => email, "password" => password}, []) do
      {:ok, user} ->
        issue_session(user)

      {:error, %AshAuthentication.Errors.AuthenticationFailed{}} ->
        {:error, :invalid_credentials}

      {:error, reason} ->
        Logger.error("Accounts.Session login failed unexpectedly: #{inspect(reason)}")
        {:error, :authentication_failed}
    end
  end

  defp sign_in_with_password(_), do: {:error, :invalid_request}

  defp refresh_session(refresh_token) when is_binary(refresh_token) do
    with {:ok, user, token_resource} <- authenticate_refresh_token(refresh_token),
         {:ok, session} <- issue_session(user),
         :ok <- revoke_token(token_resource, refresh_token) do
      {:ok, session}
    else
      {:error, :invalid_refresh_token} = error ->
        error

      {:error, :token_revocation_failed} = error ->
        error

      {:error, :token_generation_failed} = error ->
        error

      {:error, reason} ->
        Logger.error("Accounts.Session refresh failed unexpectedly: #{inspect(reason)}")
        {:error, :authentication_failed}
    end
  end

  defp refresh_session(_), do: {:error, :invalid_request}

  defp logout_session(nil, nil), do: {:error, :invalid_request}

  defp logout_session(access_token, refresh_token) do
    with :ok <- maybe_revoke_token(access_token),
         :ok <- maybe_revoke_token(refresh_token) do
      {:ok, %{revoked: true}}
    else
      {:error, :invalid_token} = error ->
        error

      {:error, reason} ->
        Logger.error("Accounts.Session logout failed unexpectedly: #{inspect(reason)}")
        {:error, :authentication_failed}
    end
  end

  defp issue_session(user) do
    with {:ok, access_token, access_claims} <- ensure_access_token(user),
         {:ok, refresh_token, refresh_claims} <- generate_refresh_token(user) do
      {:ok,
       %{
         user: %{
           id: user.id,
           email: to_string(user.email)
         },
         session: %{
           token_type: "Bearer",
           access_token: access_token,
           access_token_expires_at: unix_to_iso8601(access_claims["exp"]),
           refresh_token: refresh_token,
           refresh_token_expires_at: unix_to_iso8601(refresh_claims["exp"])
         }
       }}
    end
  end

  defp acquire_bootstrap_lock do
    case Repo.query("SELECT pg_advisory_xact_lock($1)", [@bootstrap_lock_key]) do
      {:ok, _result} -> :ok
      {:error, reason} -> {:error, reason}
    end
  end

  defp ensure_bootstrap_available do
    case User |> Query.limit(1) |> Ash.read(authorize?: false) do
      {:ok, []} -> :ok
      {:ok, [_user]} -> {:error, :bootstrap_unavailable}
      {:error, reason} -> {:error, reason}
    end
  end

  defp create_bootstrap_user(params) do
    case Ash.create(
           User,
           params,
           action: :bootstrap_local_account,
           authorize?: false,
           return_notifications?: true
         ) do
      {:ok, user, notifications} ->
        {:ok, user, notifications}

      {:error, %Ash.Error.Invalid{}} ->
        {:error, :invalid_bootstrap_request}

      {:error, reason} ->
        {:error, reason}
    end
  end

  defp ensure_access_token(%{__metadata__: %{token: token}} = user) when is_binary(token) do
    case Jwt.peek(token) do
      {:ok, claims} -> {:ok, token, claims}
      {:error, _reason} -> generate_access_token(user)
    end
  end

  defp ensure_access_token(user), do: generate_access_token(user)

  defp generate_access_token(user) do
    case Jwt.token_for_user(user) do
      {:ok, token, claims} -> {:ok, token, claims}
      :error -> {:error, :token_generation_failed}
    end
  end

  defp generate_refresh_token(user) do
    case Jwt.token_for_user(user, %{"typ" => @refresh_purpose}, purpose: :refresh) do
      {:ok, token, claims} -> {:ok, token, claims}
      :error -> {:error, :token_generation_failed}
    end
  end

  defp authenticate_refresh_token(token) do
    with {:ok, claims, User} <- Jwt.verify(token, @otp_app),
         @refresh_purpose <- Map.get(claims, "typ"),
         {:ok, token_resource} <- Info.authentication_tokens_token_resource(User),
         {:ok, [_token_record]} <-
           TokenResource.Actions.get_token(
             token_resource,
             %{"jti" => claims["jti"], "purpose" => @refresh_purpose}
           ),
         {:ok, user} <- AshAuthentication.subject_to_user(claims["sub"], User, []) do
      {:ok, user, token_resource}
    else
      _ -> {:error, :invalid_refresh_token}
    end
  end

  defp maybe_revoke_token(nil), do: :ok

  defp maybe_revoke_token(token) when is_binary(token) do
    with {:ok, resource} <- Jwt.token_to_resource(token, @otp_app),
         {:ok, token_resource} <- Info.authentication_tokens_token_resource(resource),
         :ok <- revoke_token(token_resource, token) do
      :ok
    else
      _ -> {:error, :invalid_token}
    end
  end

  defp maybe_revoke_token(_), do: {:error, :invalid_token}

  defp revoke_token(token_resource, token) do
    case TokenResource.Actions.revoke(token_resource, token) do
      :ok -> :ok
      {:error, _reason} -> {:error, :token_revocation_failed}
    end
  end

  defp unix_to_iso8601(unix) when is_integer(unix) do
    unix
    |> DateTime.from_unix!()
    |> DateTime.to_iso8601()
  end
end
