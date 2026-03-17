defmodule MookServer.Communities do
  use Ash.Domain, otp_app: :mook_server, extensions: [AshAdmin.Domain]

  admin do
    show? true
  end

  resources do
  end
end
