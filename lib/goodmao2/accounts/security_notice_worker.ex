defmodule Goodmao2.Accounts.SecurityNoticeWorker do
  @moduledoc """
  Emails an account a notice that one of its security settings just changed, off the request
  path (`Goodmao2.Accounts.notify_security_event/3`).

  Without it a hijacked session could change the password, the address, or the second factor
  and the owner would never know — after an email change, the magic links themselves go to the
  new address. So an email change is told to the address it **replaced**, and every other event
  to the account's current address. The notice carries no link and no token: it only says what
  changed and when, and what to do if it was not the owner.
  """
  use Oban.Worker, queue: :default, max_attempts: 3

  alias Goodmao2.Accounts
  alias Goodmao2.Accounts.UserNotifier

  @impl Oban.Worker
  def perform(%Oban.Job{args: %{"user_id" => user_id, "event" => event} = args, inserted_at: at}) do
    with %{} = user <- Accounts.get_user(user_id),
         true <- event in UserNotifier.security_events() do
      to = args["to"] || user.email

      case UserNotifier.deliver_security_notice(to, event, at) do
        {:ok, _email} -> :ok
        error -> error
      end
    else
      _ -> :ok
    end
  end
end
