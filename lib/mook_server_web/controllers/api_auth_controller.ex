defmodule MookServerWeb.ApiAuthController do
  use MookServerWeb, :controller

  alias MookServer.Accounts.Session

  @session_error_reasons [
    :invalid_request,
    :invalid_bootstrap_request,
    :invalid_credentials,
    :bootstrap_unavailable,
    :invalid_refresh_token,
    :invalid_token,
    :authentication_failed
  ]

  def bootstrap(conn, params) do
    case Session.bootstrap(params) do
      {:ok, payload} ->
        render_success(conn, payload)

      {:error, reason} ->
        render_error(conn, normalize_session_error(:bootstrap, reason))
    end
  end

  def login(conn, params) do
    case Session.login(params) do
      {:ok, payload} ->
        render_success(conn, payload)

      {:error, reason} ->
        render_error(conn, normalize_session_error(:login, reason))
    end
  end

  def refresh(conn, %{"refresh_token" => refresh_token}) do
    case Session.refresh(refresh_token) do
      {:ok, payload} ->
        render_success(conn, payload)

      {:error, reason} ->
        render_error(conn, normalize_session_error(:refresh, reason))
    end
  end

  def refresh(conn, _params), do: render_error(conn, :invalid_request)

  def logout(conn, params) do
    access_token = bearer_token(conn)
    refresh_token = Map.get(params, "refresh_token")

    case Session.logout(access_token, refresh_token) do
      {:ok, payload} ->
        render_success(conn, payload)

      {:error, reason} ->
        render_error(conn, normalize_session_error(:logout, reason))
    end
  end

  defp render_success(conn, payload) do
    conn
    |> put_status(:ok)
    |> json(%{data: payload})
  end

  defp render_error(conn, reason) do
    {status, code, message} = error_response(reason)

    conn
    |> put_status(status)
    |> json(%{
      error: %{
        code: code,
        message: message
      }
    })
  end

  defp error_response(:invalid_request),
    do: {:bad_request, "invalid_request", "Required authentication parameters were not provided"}

  defp error_response(:invalid_bootstrap_request),
    do:
      {:bad_request, "invalid_request",
       "Provided bootstrap parameters were invalid or incomplete"}

  defp error_response(:invalid_credentials),
    do: {:unauthorized, "invalid_credentials", "Invalid email or password"}

  defp error_response(:bootstrap_unavailable),
    do:
      {:conflict, "bootstrap_unavailable",
       "Local account bootstrap is no longer available on this server"}

  defp error_response(:invalid_refresh_token),
    do: {:unauthorized, "invalid_refresh_token", "Refresh token is invalid or expired"}

  defp error_response(:invalid_token),
    do: {:unauthorized, "invalid_token", "Provided token is invalid or expired"}

  defp error_response(_reason),
    do:
      {:internal_server_error, "authentication_failed",
       "Authentication request could not be completed"}

  defp bearer_token(conn) do
    conn
    |> get_req_header("authorization")
    |> Enum.find_value(fn
      "Bearer " <> token -> token
      _ -> nil
    end)
  end

  defp normalize_session_error(:bootstrap, %Ash.Error.Invalid{} = reason) do
    extract_session_reason(reason) || :invalid_bootstrap_request
  end

  defp normalize_session_error(_action, %Ash.Error.Invalid{} = reason) do
    extract_session_reason(reason) || :invalid_request
  end

  defp normalize_session_error(_action, %Ash.Error.Unknown{} = reason) do
    extract_session_reason(reason) || :authentication_failed
  end

  defp normalize_session_error(_action, reason), do: reason

  defp extract_session_reason(reason) when reason in @session_error_reasons, do: reason

  defp extract_session_reason(%{errors: errors}) when is_list(errors) do
    Enum.find_value(errors, &extract_session_reason/1)
  end

  defp extract_session_reason(%{error: error}), do: extract_session_reason(error)

  defp extract_session_reason(reason) do
    inspected = inspect(reason)

    Enum.find(@session_error_reasons, fn candidate ->
      String.contains?(inspected, Atom.to_string(candidate))
    end)
  end
end
