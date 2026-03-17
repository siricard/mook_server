defmodule MookServer.Accounts.SessionTest do
  use MookServer.DataCase

  alias AshAuthentication.{Info, Strategy}
  alias AshAuthentication.TokenResource.Actions, as: TokenActions
  alias MookServer.Accounts.{Session, User}

  defp register_user!(attrs \\ %{}) do
    unique = System.unique_integer([:positive])
    email = Map.get(attrs, :email, "user#{unique}@example.com")
    password = Map.get(attrs, :password, "supersecret123")

    params = %{
      "email" => email,
      "password" => password,
      "password_confirmation" => password
    }

    strategy = Info.strategy!(User, :password)
    assert {:ok, _user} = Strategy.action(strategy, :register, params, [])

    %{email: email, password: password}
  end

  defp assert_session_error({:error, reason}, expected_reason) do
    assert extract_reason(reason) == expected_reason
  end

  defp extract_reason(reason) when is_atom(reason), do: reason

  defp extract_reason(%{errors: errors}) when is_list(errors) do
    Enum.find_value(errors, &extract_reason/1)
  end

  defp extract_reason(%{error: error}), do: extract_reason(error)

  defp extract_reason(reason) do
    inspected = inspect(reason)

    Enum.find(
      [:invalid_credentials, :invalid_refresh_token],
      fn candidate ->
        String.contains?(inspected, Atom.to_string(candidate))
      end
    )
  end

  test "bootstrap/1 creates the first local account and returns a session payload" do
    email = "owner@example.com"
    password = "supersecret123"

    assert {:ok,
            %{
              user: %{id: user_id, email: ^email},
              session: %{access_token: access_token, refresh_token: refresh_token}
            }} =
             Session.bootstrap(%{
               email: email,
               password: password,
               password_confirmation: password
             })

    assert is_binary(user_id)
    assert is_binary(access_token)
    assert is_binary(refresh_token)
  end

  test "login/1 returns invalid credentials for a bad password" do
    %{email: email} = register_user!()

    Session.login(%{
      email: email,
      password: "wrong-password"
    })
    |> assert_session_error(:invalid_credentials)
  end

  test "refresh/1 rotates the refresh token" do
    %{email: email, password: password} = register_user!()

    assert {:ok, %{session: %{refresh_token: old_refresh_token}}} =
             Session.login(%{email: email, password: password})

    assert {:ok,
            %{
              user: %{email: ^email},
              session: %{access_token: access_token, refresh_token: new_refresh_token}
            }} = Session.refresh(old_refresh_token)

    assert is_binary(access_token)
    assert new_refresh_token != old_refresh_token

    Session.refresh(old_refresh_token)
    |> assert_session_error(:invalid_refresh_token)
  end

  test "logout/2 revokes provided tokens" do
    %{email: email, password: password} = register_user!()

    assert {:ok, %{user: %{email: ^email}, session: session}} =
             Session.login(%{email: email, password: password})

    assert {:ok, %{revoked: true}} =
             Session.logout(session.access_token, session.refresh_token)

    assert TokenActions.token_revoked?(MookServer.Accounts.Token, session.access_token)
    assert TokenActions.token_revoked?(MookServer.Accounts.Token, session.refresh_token)
  end
end
