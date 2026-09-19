defmodule Goodmao2Web.FeatureCase do
  @moduledoc """
  Case template for browser-driven feature tests (Wallaby + Selenium/Firefox).

  These are the only tests that run the real client: JavaScript executes, the service worker
  registers, `phx-hook`s mount, and CSS lays out. Everything under `test/goodmao2_web/live`
  drives the LiveView process directly and never loads a page, so a hook that throws, a
  `phx-hook` name that is not registered, or a script that silently does nothing all pass the
  rest of the suite while the page is broken in a browser.

  They are excluded from `mix test` (see `test/test_helper.exs`) because they need a browser
  and a Selenium server. Run them with `mix test.feature`, after `mix selenium.setup` once.

  `import Wallaby.Feature` + `use Wallaby.DSL` rather than `use Wallaby.Feature`: the latter
  installs its own `setup`, which runs before this one and leaves the W3C `create_session_fn`
  unset.

  ## Usage

      defmodule Goodmao2Web.Features.SomethingTest do
        use Goodmao2Web.FeatureCase, async: false

        @moduletag :feature

        feature "shows the landing page", %{session: session} do
          session
          |> visit("/")
          |> assert_has(Query.css("#landing-title"))
        end
      end
  """

  use ExUnit.CaseTemplate
  use Wallaby.DSL

  # Every rate limiter in the app is a per-address or per-user ETS sliding window. A browser
  # test arrives from 127.0.0.1 as the same user over and over, so without clearing these a
  # later test is throttled by an earlier one. All four tables are :public and :named_table.
  @rate_limit_tables [
    :login_attempt_rate,
    :registration_email_rate,
    :media_upload_rate,
    :message_send_rate
  ]

  using do
    quote do
      use Wallaby.DSL

      import Wallaby.Feature
      import Goodmao2.AccountsFixtures
      import Goodmao2.PetsFixtures

      import Goodmao2Web.FeatureCase,
        only: [
          start_another_session: 0,
          browser_user_fixture: 0,
          browser_user_fixture: 1,
          log_in_via_browser: 1,
          log_in_via_browser: 2,
          submit_login_form: 3,
          log_in_with_totp_via_browser: 3,
          totp_code: 2,
          wait_for_path: 2,
          js_value: 2,
          add_virtual_authenticator: 1
        ]

      alias Goodmao2.Repo
    end
  end

  setup _tags do
    :ok = Ecto.Adapters.SQL.Sandbox.checkout(Goodmao2.Repo)
    Ecto.Adapters.SQL.Sandbox.mode(Goodmao2.Repo, {:shared, self()})

    Enum.each(@rate_limit_tables, fn table ->
      if :ets.whereis(table) != :undefined, do: :ets.delete_all_objects(table)
    end)

    put_browser_webauthn_origin()

    {:ok, session: start_another_session()}
  end

  # `config/test.exs` pins the wax_ origin to https://localhost:4001 because the stored
  # WebAuthn ceremony fixtures were captured there. A real browser sends the origin it is
  # actually on, which is Wallaby's base_url, so the ceremony would be rejected. Both values
  # are read through Application.get_env at call time (Accounts.WebAuthn), so pointing them
  # at the browser's origin for the duration of a feature test leaves the fixture-based tests
  # untouched.
  defp put_browser_webauthn_origin do
    previous = Application.get_env(:wax_, :origin)
    Application.put_env(:wax_, :origin, Application.fetch_env!(:wallaby, :base_url))
    ExUnit.Callbacks.on_exit(fn -> Application.put_env(:wax_, :origin, previous) end)
  end

  @doc """
  Starts a browser session sharing this test's database sandbox, ending when the test does.

  The setup starts the first one; call this for a second browser, e.g. to watch one caretaker
  see another's log entry arrive over PubSub.
  """
  def start_another_session do
    metadata = Phoenix.Ecto.SQL.Sandbox.metadata_for(Goodmao2.Repo, self())

    {:ok, session} =
      Wallaby.start_session(
        create_session_fn: &Goodmao2Web.W3CWebDriver.create_session/2,
        metadata: metadata
      )

    ExUnit.Callbacks.on_exit(fn -> Wallaby.end_session(session) end)

    # Wide enough for the `lg:` desktop nav. Below it the shell renders the hamburger copy
    # instead, whose ids are `m-` prefixed, so a test written against the canonical ids would
    # fail on element visibility rather than on anything it meant to check.
    resize_window(session, 1280, 900)
  end

  @doc """
  A confirmed user who can sign in with a password.

  `user_fixture/1` confirms through a magic link and leaves the account **passwordless**, so
  it cannot be used with the email+password form the browser drives.
  """
  def browser_user_fixture(attrs \\ %{}) do
    attrs |> Goodmao2.AccountsFixtures.user_fixture() |> Goodmao2.AccountsFixtures.set_password()
  end

  @doc """
  Creates a password user, signs them in through the login form, and returns `{session, user}`.
  """
  def log_in_via_browser(session) do
    user = browser_user_fixture()
    {log_in_via_browser(session, user), user}
  end

  @doc """
  Signs `user` in through the real login form and waits for the pet list.

  The user needs a password (`browser_user_fixture/1`) and no second factor.
  """
  def log_in_via_browser(session, user) do
    session
    |> submit_login_form(user.email, Goodmao2.AccountsFixtures.valid_user_password())
    |> assert_has(Query.css("#pets-heading"))
  end

  @doc """
  Fills in and submits the email+password login form, without waiting for the outcome.
  """
  # Scoped to the password form rather than addressed by field id: the page carries two forms
  # bound to the same changeset, and only the email input is namespaced by its form
  # (`login_form_password_email`) -- the password input renders as plain `user_password`.
  # The form also has two submit buttons; the one carrying `name` is "stay logged in".
  def submit_login_form(session, email, password) do
    session
    |> visit("/users/log-in")
    |> fill_in(Query.css("#login_form_password input[type=email]"), with: email)
    |> fill_in(Query.css("#login_form_password input[type=password]"), with: password)
    |> click(Query.css("#login_form_password button[type=submit][name]"))
  end

  @doc """
  Returns a current TOTP code for `secret`.

  Clears the single-use marker first: `totp_last_used_at` rejects a replay inside the same
  30-second step (ADR-0013), which a test hits whenever it verifies twice in one second.
  """
  def totp_code(user, secret) do
    user
    |> Ecto.Changeset.change(totp_last_used_at: nil)
    |> Goodmao2.Repo.update!()

    NimbleTOTP.verification_code(secret)
  end

  @doc """
  Signs in a user whose TOTP is enabled, through the login form and the second-factor page.
  """
  def log_in_with_totp_via_browser(session, user, secret) do
    session
    |> submit_login_form(user.email, Goodmao2.AccountsFixtures.valid_user_password())
    |> assert_has(Query.css("#totp_challenge_form"))
    |> fill_in(Query.css("#totp_challenge_form input[name='user[totp_code]']"),
      with: totp_code(user, secret)
    )
    |> click(Query.css("#totp-challenge-submit"))
    |> assert_has(Query.css("#pets-heading"))
  end

  @doc """
  Waits up to 5 seconds for the browser to reach `path`, for redirects that leave nothing
  distinctive to assert on.
  """
  def wait_for_path(session, path), do: wait_for_path(session, URI.parse(path).path, 50)

  defp wait_for_path(session, path, 0),
    do: raise("never reached #{path}; still at #{current_path(session)}")

  defp wait_for_path(session, path, tries) do
    if current_path(session) == path do
      session
    else
      Process.sleep(100)
      wait_for_path(session, path, tries - 1)
    end
  end

  @doc """
  Runs `script` (which must `return` a value) in the browser and gives back the value.
  """
  def js_value(session, script) do
    parent = self()
    ref = make_ref()
    execute_script(session, script, fn value -> send(parent, {ref, value}) end)

    receive do
      {^ref, value} -> value
    after
      5_000 -> raise "no value returned from script"
    end
  end

  @doc """
  Adds a WebDriver virtual authenticator, so a WebAuthn registration or assertion completes
  without a physical security key. Needs the Firefox WebAuthn prefs in `config/test.exs`.
  """
  def add_virtual_authenticator(session) do
    {:ok, %{"value" => id}} =
      Wallaby.HTTPClient.request(:post, "#{session.session_url}/webauthn/authenticator", %{
        protocol: "ctap2",
        transport: "internal",
        hasResidentKey: true,
        hasUserVerification: true,
        isUserConsenting: true,
        isUserVerified: true
      })

    {session, id}
  end
end
