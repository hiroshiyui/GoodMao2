defmodule Goodmao2.Accounts.LoginLinkWorker do
  @moduledoc """
  Mints and emails a magic-link login (or confirmation) token for a user, off the request path.

  The magic-link and registration forms answer identically whether or not the address has an
  account, but sending mail inline made the *time* differ: only a registered address waited on
  the outbound SES call, so response latency was a membership oracle. The request now only
  enqueues this job (a small insert) for a known account. A thin shell over
  `Goodmao2.Accounts.deliver_login_instructions/2`; the job carries only the user id — the raw
  token is minted here and exists nowhere but the email.
  """
  use Oban.Worker, queue: :default, max_attempts: 3
  use Goodmao2Web, :verified_routes

  alias Goodmao2.Accounts

  @impl Oban.Worker
  def perform(%Oban.Job{args: %{"user_id" => user_id}}) do
    case Accounts.get_user(user_id) do
      nil ->
        :ok

      user ->
        with {:ok, _email} <-
               Accounts.deliver_login_instructions(user, &url(~p"/users/log-in/#{&1}")),
             do: :ok
    end
  end
end
