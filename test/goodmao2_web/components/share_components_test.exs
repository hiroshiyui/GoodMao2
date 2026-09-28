defmodule Goodmao2Web.ShareComponentsTest do
  # The copy/share behaviour runs in the browser (assets/js/clipboard.js); what the server owns —
  # and what these pin — is everything the client needs to never fail silently: the localized
  # outcome labels, the status region it writes into, and the hidden-until-supported share button.
  use ExUnit.Case, async: true

  import Phoenix.LiveViewTest
  import Goodmao2Web.ShareComponents

  defp render_link do
    render_component(&share_link/1,
      id: "demo-share",
      url: "https://example.test/entries/shared/abc",
      label: "Share link URL",
      share_title: "Food entry"
    )
  end

  test "the copy button names its source, its status region, and both outcomes" do
    doc = render_link() |> LazyHTML.from_fragment()

    [copy] = doc |> LazyHTML.query("#demo-share-copy") |> Enum.to_list()
    attr = fn node, name -> node |> LazyHTML.attribute(name) |> List.first() end

    assert attr.(copy, "phx-hook") == "Clipboard"
    assert attr.(copy, "data-clipboard-target") == "#demo-share-url"
    assert attr.(copy, "data-clipboard-status") == "#demo-share-status"
    assert attr.(copy, "data-copied-label") == "Link copied."
    assert attr.(copy, "data-copy-failed-label") =~ "Couldn't copy"

    # The status region exists before anything is written to it, and patches leave it alone.
    [status] = doc |> LazyHTML.query("#demo-share-status") |> Enum.to_list()
    assert attr.(status, "role") == "status"
    assert attr.(status, "phx-update") == "ignore"

    [url] = doc |> LazyHTML.query("#demo-share-url") |> Enum.to_list()
    assert attr.(url, "value") == "https://example.test/entries/shared/abc"
    assert attr.(url, "aria-label") == "Share link URL"
  end

  test "the platform share button is hidden until the hook finds navigator.share" do
    doc = render_link() |> LazyHTML.from_fragment()
    [native] = doc |> LazyHTML.query("#demo-share-native") |> Enum.to_list()
    attr = fn name -> native |> LazyHTML.attribute(name) |> List.first() end

    assert attr.("phx-hook") == "WebShare"
    assert attr.("hidden") != nil
    assert attr.("data-share-url") == "https://example.test/entries/shared/abc"
    assert attr.("data-share-title") == "Food entry"
    assert attr.("phx-mounted") =~ "ignore_attrs"
  end
end
