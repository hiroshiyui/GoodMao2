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

  describe "table/1 row_click" do
    defp row_click_table(row_click) do
      render_component(&table/1,
        id: "pets",
        rows: [%{id: 1, name: "Mao", age: "3"}],
        row_click: row_click,
        col: [
          %{label: "Name", inner_block: fn _slot, row -> row.name end},
          %{label: "Age", inner_block: fn _slot, row -> row.age end}
        ]
      )
    end

    test "puts an activatable row in a real control, not on the cell" do
      # phx-click on a <td> is mouse-only: a table cell cannot take focus, so a keyboard user
      # can never reach the action.
      html = row_click_table(fn row -> "select-#{row.id}" end)

      assert html =~ ~s(<button)
      assert html =~ ~s(phx-click="select-1")
      assert html =~ ~s(type="button")
      refute html =~ ~s(<td phx-click)
    end

    test "leaves one tab stop per row, not one per cell" do
      html = row_click_table(fn row -> "select-#{row.id}" end)

      # Both cells stay clickable, but only the first is reachable by Tab -- otherwise every
      # column of every row becomes its own stop for the same single action.
      assert length(String.split(html, ~s(phx-click="select-1"))) - 1 == 2
      assert length(String.split(html, ~s(tabindex="-1"))) - 1 == 1
    end

    test "adds no control when rows are not activatable" do
      html = row_click_table(nil)

      refute html =~ "<button"
      refute html =~ "tabindex"
      assert html =~ "Mao"
    end
  end
end
