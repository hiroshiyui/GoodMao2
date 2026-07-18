# Script for populating the database. Run it with:
#
#     mix run priv/repo/seeds.exs
#
# It is idempotent: it upserts a demo owner + vet, a cat, and a handful of
# structured log entries so the timeline has something to show in development.

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

IO.puts("""
Seeded demo data:
  owner@example.com / password1234!   (@amy — administrator, owns Mochi)
  vet@example.com   / password1234!   (@dr_lin — time-boxed vet grant)
""")
