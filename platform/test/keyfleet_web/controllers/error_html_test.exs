defmodule KeyfleetWeb.ErrorHTMLTest do
  use KeyfleetWeb.ConnCase, async: true

  # Bring render_to_string/4 for testing custom views
  import Phoenix.Template, only: [render_to_string: 4]

  test "renders 404.html" do
    assert render_to_string(KeyfleetWeb.ErrorHTML, "404", "html", []) =~
             "We can’t find that page</h1>"
  end

  test "a missing page offers the homepage once, as its button, then the other ways on" do
    page = render_to_string(KeyfleetWeb.ErrorHTML, "404", "html", []) |> LazyHTML.from_document()

    assert page |> LazyHTML.query("a[href='/']") |> Enum.count() == 1
    assert page |> LazyHTML.query(".rg-utility__links a[href='/docs']") |> Enum.count() == 1
  end

  test "a missing page under a fleet's pages leads back to that fleet, the homepage among the other ways on" do
    page =
      render_to_string(KeyfleetWeb.ErrorHTML, "404", "html",
        conn: build_conn(:get, "/classic/1/rooms")
      )
      |> LazyHTML.from_document()

    assert page |> LazyHTML.query(".rg-button[href='/classic/1']") |> LazyHTML.text() ==
             "Go to Classic #1"

    assert page |> LazyHTML.query(".rg-utility__links a[href='/']") |> Enum.count() == 1

    elsewhere =
      render_to_string(KeyfleetWeb.ErrorHTML, "404", "html",
        conn: build_conn(:get, "/classic/10")
      )

    assert elsewhere =~ "Go to the homepage"
  end

  test "renders 500.html" do
    assert render_to_string(KeyfleetWeb.ErrorHTML, "500", "html", []) =~
             "Something went wrong</h1>"
  end

  test "a server fault on a page offers to load it again, never to send a form again" do
    opened = build_conn(:get, "/classic/1?view=members")
    sent = build_conn(:post, "/early")

    assert render_to_string(KeyfleetWeb.ErrorHTML, "500", "html", conn: opened) =~
             ~s(<a class="rg-button rg-button--primary" href="">Try again</a>)

    refute render_to_string(KeyfleetWeb.ErrorHTML, "500", "html", conn: sent) =~ "Try again"
  end
end
