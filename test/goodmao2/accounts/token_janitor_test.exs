defmodule Goodmao2.Accounts.TokenJanitorTest do
  use Goodmao2.DataCase
  use Oban.Testing, repo: Goodmao2.Repo

  import Goodmao2.AccountsFixtures

  alias Goodmao2.Accounts.{TokenJanitor, UserToken}

  test "prunes expired tokens when the job runs" do
    user = user_fixture()

    expired =
      %UserToken{
        token: :crypto.strong_rand_bytes(32),
        context: "session",
        user_id: user.id
      }
      |> Repo.insert!()
      |> Ecto.Changeset.change(inserted_at: DateTime.add(DateTime.utc_now(:second), -30, :day))
      |> Repo.update!()

    assert :ok = perform_job(TokenJanitor, %{})
    refute Repo.get(UserToken, expired.id)
  end
end
