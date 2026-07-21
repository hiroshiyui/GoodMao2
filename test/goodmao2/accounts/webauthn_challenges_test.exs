defmodule Goodmao2.Accounts.WebAuthnChallengesTest do
  # Not async: shares the global named ETS table with any other WebAuthn test.
  use ExUnit.Case, async: false

  alias Goodmao2.Accounts.WebAuthnChallenges

  defp challenge,
    do: Wax.new_registration_challenge(origin: "https://localhost:4001", rp_id: "localhost")

  test "put then pop returns the challenge for the right user" do
    token = WebAuthnChallenges.put(1, challenge())
    assert {:ok, %Wax.Challenge{}} = WebAuthnChallenges.pop(token, 1)
  end

  test "pop is single-use" do
    token = WebAuthnChallenges.put(2, challenge())
    assert {:ok, _} = WebAuthnChallenges.pop(token, 2)
    assert {:error, :not_found} = WebAuthnChallenges.pop(token, 2)
  end

  test "pop rejects a mismatched user_id" do
    token = WebAuthnChallenges.put(3, challenge())
    assert {:error, :not_found} = WebAuthnChallenges.pop(token, 999)
    # pop uses :ets.take, so a mismatched attempt still consumes the single-use token.
    assert {:error, :not_found} = WebAuthnChallenges.pop(token, 3)
  end

  test "pop rejects an unknown token" do
    assert {:error, :not_found} = WebAuthnChallenges.pop("nope", 1)
    assert {:error, :not_found} = WebAuthnChallenges.pop(:not_a_binary, 1)
  end
end
