defmodule MookServerWeb.ApiAuthControllerTest do
  use MookServerWeb.ConnCase

  alias AshAuthentication.{Info, Strategy}
  alias AshAuthentication.TokenResource.Actions, as: TokenActions
  alias MookServer.Accounts.User

  defp json_conn(conn) do
    put_req_header(conn, "accept", "application/json")
  end

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

  defp login!(email, password) do
    conn =
      build_conn()
      |> json_conn()
      |> post(~p"/api/v1/auth/login", %{email: email, password: password})

    %{"data" => data} = json_response(conn, 200)
    data
  end

  test "POST /api/v1/auth/bootstrap creates the first local account and returns a session", %{
    conn: conn
  } do
    email = "owner@example.com"
    password = "supersecret123"

    conn =
      post(json_conn(conn), ~p"/api/v1/auth/bootstrap", %{
        email: email,
        password: password,
        password_confirmation: password
      })

    assert %{
             "data" => %{
               "user" => %{"id" => user_id, "email" => ^email},
               "session" => %{
                 "token_type" => "Bearer",
                 "access_token" => access_token,
                 "refresh_token" => refresh_token
               }
             }
           } = json_response(conn, 200)

    assert is_binary(user_id)
    assert is_binary(access_token)
    assert is_binary(refresh_token)

    login_conn =
      build_conn()
      |> json_conn()
      |> post(~p"/api/v1/auth/login", %{email: email, password: password})

    assert %{"data" => %{"user" => %{"email" => ^email}}} = json_response(login_conn, 200)
  end

  test "POST /api/v1/auth/bootstrap is unavailable after the first local account exists", %{
    conn: conn
  } do
    register_user!()

    conn =
      post(json_conn(conn), ~p"/api/v1/auth/bootstrap", %{
        email: "owner@example.com",
        password: "supersecret123",
        password_confirmation: "supersecret123"
      })

    assert %{
             "error" => %{
               "code" => "bootstrap_unavailable",
               "message" => "Local account bootstrap is no longer available on this server"
             }
           } = json_response(conn, 409)
  end

  test "POST /api/v1/auth/bootstrap returns normalized failure for invalid params", %{conn: conn} do
    conn =
      post(json_conn(conn), ~p"/api/v1/auth/bootstrap", %{
        email: "owner@example.com",
        password: "short",
        password_confirmation: "mismatch"
      })

    assert %{
             "error" => %{
               "code" => "invalid_request",
               "message" => "Provided bootstrap parameters were invalid or incomplete"
             }
           } = json_response(conn, 400)
  end

  test "POST /api/v1/auth/login returns session material for valid credentials", %{conn: conn} do
    %{email: email, password: password} = register_user!()

    conn = post(json_conn(conn), ~p"/api/v1/auth/login", %{email: email, password: password})

    assert %{
             "data" => %{
               "user" => %{"id" => user_id, "email" => ^email},
               "session" => %{
                 "token_type" => "Bearer",
                 "access_token" => access_token,
                 "access_token_expires_at" => access_token_expires_at,
                 "refresh_token" => refresh_token,
                 "refresh_token_expires_at" => refresh_token_expires_at
               }
             }
           } = json_response(conn, 200)

    assert is_binary(user_id)
    assert is_binary(access_token)
    assert is_binary(refresh_token)
    assert is_binary(access_token_expires_at)
    assert is_binary(refresh_token_expires_at)
  end

  test "POST /api/v1/auth/login returns normalized failure for invalid credentials", %{conn: conn} do
    register_user!()

    conn =
      post(json_conn(conn), ~p"/api/v1/auth/login", %{
        email: "nobody@example.com",
        password: "wrong-password"
      })

    assert %{
             "error" => %{
               "code" => "invalid_credentials",
               "message" => "Invalid email or password"
             }
           } = json_response(conn, 401)
  end

  test "POST /api/v1/auth/refresh rotates the refresh token and returns a new session", %{
    conn: conn
  } do
    %{email: email, password: password} = register_user!()
    login_data = login!(email, password)
    old_refresh_token = get_in(login_data, ["session", "refresh_token"])

    conn =
      post(json_conn(conn), ~p"/api/v1/auth/refresh", %{
        refresh_token: old_refresh_token
      })

    assert %{
             "data" => %{
               "user" => %{"email" => ^email},
               "session" => %{
                 "access_token" => new_access_token,
                 "refresh_token" => new_refresh_token
               }
             }
           } = json_response(conn, 200)

    assert is_binary(new_access_token)
    assert new_refresh_token != old_refresh_token

    old_refresh_conn =
      build_conn()
      |> json_conn()
      |> post(~p"/api/v1/auth/refresh", %{refresh_token: old_refresh_token})

    assert %{
             "error" => %{
               "code" => "invalid_refresh_token",
               "message" => "Refresh token is invalid or expired"
             }
           } = json_response(old_refresh_conn, 401)
  end

  test "POST /api/v1/auth/refresh returns normalized failure for an invalid refresh token", %{
    conn: conn
  } do
    conn =
      post(json_conn(conn), ~p"/api/v1/auth/refresh", %{
        refresh_token: "not-a-token"
      })

    assert %{
             "error" => %{
               "code" => "invalid_refresh_token",
               "message" => "Refresh token is invalid or expired"
             }
           } = json_response(conn, 401)
  end

  test "POST /api/v1/auth/logout revokes provided access and refresh tokens", %{conn: conn} do
    %{email: email, password: password} = register_user!()
    login_data = login!(email, password)
    access_token = get_in(login_data, ["session", "access_token"])
    refresh_token = get_in(login_data, ["session", "refresh_token"])

    conn =
      conn
      |> json_conn()
      |> put_req_header("authorization", "Bearer #{access_token}")
      |> post(~p"/api/v1/auth/logout", %{refresh_token: refresh_token})

    assert %{"data" => %{"revoked" => true}} = json_response(conn, 200)
    assert TokenActions.token_revoked?(MookServer.Accounts.Token, access_token)
    assert TokenActions.token_revoked?(MookServer.Accounts.Token, refresh_token)

    refresh_conn =
      build_conn()
      |> json_conn()
      |> post(~p"/api/v1/auth/refresh", %{refresh_token: refresh_token})

    assert %{"error" => %{"code" => "invalid_refresh_token"}} = json_response(refresh_conn, 401)
  end

  test "POST /api/v1/auth/logout returns normalized failure when no tokens are provided", %{
    conn: conn
  } do
    conn = post(json_conn(conn), ~p"/api/v1/auth/logout", %{})

    assert %{
             "error" => %{
               "code" => "invalid_request",
               "message" => "Required authentication parameters were not provided"
             }
           } = json_response(conn, 400)
  end
end
