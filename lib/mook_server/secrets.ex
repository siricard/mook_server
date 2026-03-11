defmodule MookServer.Secrets do
  use AshAuthentication.Secret

  def secret_for(
        [:authentication, :tokens, :signing_secret],
        MookServer.Accounts.User,
        _opts,
        _context
      ) do
    Application.fetch_env(:mook_server, :token_signing_secret)
  end
end
