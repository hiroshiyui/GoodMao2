# Script for populating the database. Run it with:
#
#     mix run priv/repo/seeds.exs
#
# It is idempotent: it upserts a demo owner + vet, a cat, and a handful of
# structured log entries so the timeline has something to show in development.
#
# Development only. It plants demo accounts with a known password, so it must never
# run against a staging/production database. Tests build their own fixtures and never
# run this script.

unless Application.get_env(:goodmao2, :seed_env, Mix.env()) == :dev do
  raise """
  priv/repo/seeds.exs is a development-only script (it creates demo accounts with a
  known password) and refuses to run in #{Mix.env()}. If you really mean to seed a
  non-dev environment, do it deliberately with your own script.
  """
end

import Ecto.Query
alias Goodmao2.{Accounts, Logs, Pets, Repo}
alias Goodmao2.Accounts.User

get_or_register = fn email, attrs ->
  case Accounts.get_user_by_email(email) do
    %User{} = user ->
      user

    nil ->
      {:ok, user} = Accounts.register_user(%{email: email})

      # Confirm and set a password directly so the demo accounts can log in.
      {:ok, user} =
        user
        |> User.confirm_changeset()
        |> Ecto.Changeset.change(hashed_password: Bcrypt.hash_pwd_salt("password1234!"))
        |> Repo.update()

      {:ok, user} = Accounts.update_user_profile(user, attrs)
      user
  end
end

owner = get_or_register.("owner@example.com", %{"display_name" => "Amy", "handle" => "amy"})
vet = get_or_register.("vet@example.com", %{"display_name" => "Dr. Lin", "handle" => "dr_lin"})

pet =
  case Repo.one(from p in Pets.Pet, where: p.name == "Mochi", limit: 1) do
    nil ->
      {:ok, pet} =
        Pets.create_pet(owner, %{
          "name" => "Mochi",
          "species" => "cat",
          "sex" => "female",
          "breed" => "Domestic Shorthair",
          "color" => "calico",
          "weight_unit" => "grams"
        })

      pet

    pet ->
      pet
  end

# The vet role requires a verified VetProfile (ADR-0012). Give Dr. Lin a verified one so the
# grant below succeeds. Idempotent: submit upserts, then verify if not already verified.
{:ok, vet_profile} =
  Accounts.submit_vet_profile(vet, %{
    "license_number" => "TW-VET-0001",
    "licensing_body" => "Taiwan Veterinary Medical Association",
    "region" => "Taiwan",
    "clinic_name" => "Kindly Paws Animal Clinic",
    "specialty" => "Feline medicine"
  })

unless Accounts.verified_vet?(vet) do
  admin = Repo.one(from u in User, where: u.is_admin == true, limit: 1)
  if admin, do: Accounts.verify_vet_profile(admin, vet_profile)
end

# Give the vet a time-boxed grant (typical of a real visit).
Pets.grant_access(owner, pet, %{
  "identifier" => "dr_lin",
  "role" => "vet",
  "expires_at" => DateTime.utc_now() |> DateTime.add(7, :day) |> DateTime.truncate(:second)
})

if Logs.list_entries(owner, pet) == [] do
  hours_ago = fn h ->
    DateTime.utc_now() |> DateTime.add(-h, :hour) |> DateTime.truncate(:second)
  end

  entries = [
    {owner,
     %{
       "type" => "food",
       "data" => %{"amount" => "full", "food_type" => "wet"},
       "occurred_at" => hours_ago.(8)
     }},
    {owner,
     %{"type" => "water", "data" => %{"amount" => "normal"}, "occurred_at" => hours_ago.(7)}},
    {owner,
     %{
       "type" => "bathroom",
       "data" => %{"kind" => "urine", "straining" => true},
       "occurred_at" => hours_ago.(5),
       "note" => "Seemed uncomfortable"
     }},
    {owner,
     %{"type" => "weight", "data" => %{"weight_grams" => 4180}, "occurred_at" => hours_ago.(30)}},
    {owner,
     %{
       "type" => "energy",
       "data" => %{"level" => "3", "mood" => "quiet"},
       "occurred_at" => hours_ago.(3)
     }},
    {owner,
     %{
       "type" => "vomit",
       "data" => %{"count" => 1, "contents" => "hairball"},
       "occurred_at" => hours_ago.(6)
     }},
    {owner,
     %{
       "type" => "symptom",
       "data" => %{"symptom" => "sneezing", "severity" => 2},
       "occurred_at" => hours_ago.(4)
     }},
    {owner,
     %{
       "type" => "medication",
       "data" => %{"medication_name" => "Metacam", "dose" => "0.5 ml"},
       "occurred_at" => hours_ago.(1)
     }},
    {owner,
     %{
       "type" => "life",
       "occurred_at" => hours_ago.(9),
       "note" => "Napped in the sunbeam by the window all afternoon. 🐈"
     }},
    {vet,
     %{
       "type" => "vet_note",
       "data" => %{
         "assessment" => "Possible early cystitis; monitor litter box.",
         "recommendation" => "Increase water; recheck in 3 days."
       },
       "occurred_at" => hours_ago.(2)
     }}
  ]

  for {user, attrs} <- entries, do: Logs.create_entry(user, pet, attrs)
end

# A demo conversation between the owner and the vet (they share Mochi, so the shared-pet
# gate allows it). Idempotent: start_conversation returns the existing thread, and we only
# seed the opening messages when the thread is empty.
alias Goodmao2.Messaging

case Messaging.start_conversation(owner, "dr_lin") do
  {:ok, conversation} ->
    if Messaging.list_messages(owner, conversation) == [] do
      Messaging.send_message(owner, conversation, "Hi Dr. Lin — Mochi seemed a bit off today.")

      Messaging.send_message(
        vet,
        conversation,
        "Thanks for the note. Let's keep an eye on her water intake."
      )
    end

  _ ->
    :ok
end

IO.puts("""
Seeded demo data:
  owner@example.com / password1234!   (@amy — administrator, owns Mochi)
  vet@example.com   / password1234!   (@dr_lin — time-boxed vet grant)
""")
