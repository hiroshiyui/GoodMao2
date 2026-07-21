defmodule Goodmao2Web.UserTimezoneTest do
  # async: false — resolution reads the app-global Settings ETS cache (system default).
  use Goodmao2Web.ConnCase, async: false

  alias Goodmao2.Accounts.{Scope, User}
  alias Goodmao2.Timezone

  describe "Plugs.Timezone" do
    test "anonymous request falls back to the system default", %{conn: conn} do
      conn = conn |> assign(:current_scope, nil) |> Goodmao2Web.Plugs.Timezone.call([])
      assert conn.assigns.timezone == "Etc/UTC"
      assert Timezone.current() == "Etc/UTC"
    end

    test "a logged-in user's preference wins", %{conn: conn} do
      scope = Scope.for_user(%User{timezone: "Asia/Taipei"})
      conn = conn |> assign(:current_scope, scope) |> Goodmao2Web.Plugs.Timezone.call([])
      assert conn.assigns.timezone == "Asia/Taipei"
      assert Timezone.current() == "Asia/Taipei"
    end

    test "reflects the admin system default for anonymous requests", %{conn: conn} do
      on_exit(fn -> Goodmao2.Settings.Cache.put("default_timezone", nil) end)
      Goodmao2.Settings.put("default_timezone", "Asia/Tokyo")
      conn = conn |> assign(:current_scope, nil) |> Goodmao2Web.Plugs.Timezone.call([])
      assert conn.assigns.timezone == "Asia/Tokyo"
    end
  end

  describe "UserTimezone.on_mount/4" do
    test "assigns the resolved timezone and stashes it in the process" do
      socket = %Phoenix.LiveView.Socket{
        assigns: %{
          __changed__: %{},
          current_scope: Scope.for_user(%User{timezone: "Europe/Paris"})
        }
      }

      assert {:cont, socket} = Goodmao2Web.UserTimezone.on_mount(:put_timezone, %{}, %{}, socket)
      assert socket.assigns.timezone == "Europe/Paris"
      assert Timezone.current() == "Europe/Paris"
    end

    test "falls back to Etc/UTC for an anonymous socket" do
      socket = %Phoenix.LiveView.Socket{assigns: %{__changed__: %{}, current_scope: nil}}
      assert {:cont, socket} = Goodmao2Web.UserTimezone.on_mount(:put_timezone, %{}, %{}, socket)
      assert socket.assigns.timezone == "Etc/UTC"
    end
  end
end
