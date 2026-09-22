defmodule KeyFleetWeb.HomeLiveTest do
  use KeyFleetWeb.ConnCase, async: true

  # Invariants covered:
  # - smoke: 200 mount and the public-home landmark, outside the signed-in shell
  # - launch-gate: in-app links stay on the two product entry points, the public
  #   documents, or in-page anchors the document owns

  test "SMOKE: the homepage mounts and keeps its landmark", %{conn: conn} do
    assert conn |> get("/") |> html_response(200)
    {:ok, view, _html} = live(conn, "/")
    assert has_element?(view, "#public-home")
    refute has_element?(view, "#app-shell")
  end

  # The overview and the account page are the only product pages the homepage
  # sends visitors to; every other internal link is a public page that stays
  # open while the gate is closed.
  @open_paths ~w(/app /account /llms.txt /docs /about /contact /privacy /terms)

  test "the public homepage links only to known pages and its own anchors", %{conn: conn} do
    {:ok, _view, html} = live(conn, "/")

    anchors = attribute(html, "[id]", "id")

    for href <- attribute(html, "a", "href"),
        href != "/",
        not String.starts_with?(href, "https://") do
      assert href in @open_paths or String.starts_with?(href, "#")
      if String.starts_with?(href, "#"), do: assert(String.trim_leading(href, "#") in anchors)
    end
  end

  defp attribute(html, selector, name),
    do: html |> LazyHTML.from_document() |> LazyHTML.query(selector) |> LazyHTML.attribute(name)
end
