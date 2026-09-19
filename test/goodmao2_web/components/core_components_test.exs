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

  describe "input/1 error wiring" do
    # A red ring and an adjacent message are colour-and-proximity cues: neither reaches a screen
    # reader, which announces a field from its label, its state, and its description. Without
    # these two attributes an invalid field is indistinguishable from a valid one.
    test "marks an invalid field and points it at its message" do
      html =
        render_component(&input/1,
          id: "user_email",
          name: "user[email]",
          value: "nope",
          errors: ["must have the @ sign"]
        )

      assert html =~ ~s(aria-invalid="true")
      assert html =~ ~s(aria-describedby="user_email-error")
      assert html =~ ~s(id="user_email-error")
      assert html =~ "must have the @ sign"
    end

    test "leaves a valid field undescribed and not marked invalid" do
      html =
        render_component(&input/1,
          id: "user_email",
          name: "user[email]",
          value: "a@b.c",
          errors: []
        )

      refute html =~ "aria-invalid"
      refute html =~ "aria-describedby"
      refute html =~ "user_email-error"
    end

    test "appends the error to a description the caller already set" do
      # visibility_select/1 describes its select with its own hint; the error must join that
      # description rather than replace it, or setting a bad value would silence the hint.
      html =
        render_component(&input/1,
          id: "entry_visibility",
          name: "entry[visibility]",
          value: "bogus",
          errors: ["is invalid"],
          "aria-describedby": "entry_visibility-hint"
        )

      assert html =~ ~s(aria-describedby="entry_visibility-hint entry_visibility-error")
    end

    test "wires the same way for select, textarea and checkbox" do
      for {type, extra} <- [
            {"select", [options: [{"A", "a"}]]},
            {"textarea", []},
            {"checkbox", []}
          ] do
        html =
          render_component(
            &input/1,
            [id: "f_#{type}", name: "f[#{type}]", value: nil, type: type, errors: ["is invalid"]] ++
              extra
          )

        assert html =~ ~s(aria-invalid="true"), "#{type} is not marked invalid"
        assert html =~ ~s(aria-describedby="f_#{type}-error"), "#{type} is not described"
      end
    end
  end
end
