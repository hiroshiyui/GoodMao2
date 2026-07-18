defmodule Goodmao2.Repo do
  use Ecto.Repo,
    otp_app: :goodmao2,
    adapter: Ecto.Adapters.Postgres
end
