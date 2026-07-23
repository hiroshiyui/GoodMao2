defmodule Goodmao2Web.CoreComponentsTest do
  use Goodmao2Web.ConnCase, async: true

  import Phoenix.LiveViewTest
  import Goodmao2Web.CoreComponents

  describe "flash/1" do
    test "caps its width to the viewport so it cannot overrun a phone screen" do
      html = render_component(&flash/1, kind: :info, flash: %{"info" => "Welcome back!"})

      # The app's baseline is `html { font-size: 125% }` and the text-size control reaches
      # 175%, so a rem-only width (w-80 = 20rem) renders at 400-560px and overflows a phone.
      # The viewport-relative cap is what keeps the toast -- and its close button -- on screen.
      assert html =~ "max-w-[calc(100vw-2rem)]"
      refute html =~ "max-w-80"
    end

    test "offers a labelled close control" do
      html = render_component(&flash/1, kind: :info, flash: %{"info" => "Welcome back!"})

      assert html =~ "Welcome back!"
      assert html =~ ~s(aria-label="close")
      # Dismissal is wired on the container, so a click anywhere on the toast clears it.
      assert html =~ "lv:clear-flash"
    end

    test "renders nothing when there is no message for its kind" do
      assert render_component(&flash/1, kind: :error, flash: %{"info" => "not mine"}) =~ ""
      refute render_component(&flash/1, kind: :error, flash: %{"info" => "not mine"}) =~ "alert"
    end
  end
end
