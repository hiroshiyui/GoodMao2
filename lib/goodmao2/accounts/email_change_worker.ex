defmodule Goodmao2.Accounts.EmailChangeWorker do
  @moduledoc """
  Mints and emails the confirm-your-new-address link for an email change, off the request path.

  Like `Goodmao2.Accounts.LoginLinkWorker`: the request only enqueues (after the per-address
  `RegistrationRateLimiter` has been charged for the *target* address, so a signed-in account
  cannot pump unbounded mail at an arbitrary inbox), and the raw token is minted here and exists
  nowhere but the email. The job carries the new address and the address it is replacing; if
  the account's email moved on in between, the job is a no-op rather than a stale link.
  """
  use Oban.Worker, queue: :default, max_attempts: 3
  use Goodmao2Web, :verified_routes

  alias Goodmao2.Accounts

  @impl Oban.Worker
  def perform(%Oban.Job{
        args: %{"user_id" => user_id, "current_email" => current_email, "new_email" => new_email}
      }) do
    case Accounts.get_user(user_id) do
      %{email: ^current_email} = user ->
        with {:ok, _email} <-
               Accounts.deliver_user_update_email_instructions(
                 %{user | email: new_email},
                 current_email,
                 &url(~p"/users/settings/confirm-email/#{&1}")
               ),
             do: :ok

      _ ->
        :ok
    end
  end
end
