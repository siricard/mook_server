defmodule MookServer.Accounts do
  use Ash.Domain, otp_app: :mook_server, extensions: [AshAdmin.Domain]

  admin do
    show? true
  end

  resources do
    resource MookServer.Accounts.Session
    resource MookServer.Accounts.Token
    resource MookServer.Accounts.User
  end
end
