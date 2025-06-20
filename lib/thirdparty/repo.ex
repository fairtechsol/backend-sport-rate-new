defmodule Thirdparty.Repo do
  use Ecto.Repo,
    otp_app: :thirdparty,
    adapter: Ecto.Adapters.Postgres
end
