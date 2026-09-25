defmodule KeyfleetWeb.ActivityLinesTest do
  use ExUnit.Case, async: true

  alias KeyfleetWeb.ActivityLines

  # Invariants covered:
  # - a page shows members' words as they wrote them; Markdown escapes every
  #   one of them, so none can act as a link or formatting
  # - neither shows a character that can't be seen or reverses the text

  @post %{
    id: "post:1",
    at: ~U[2026-09-25 12:00:00Z],
    kind: :post,
    facts: %{
      by: %{token_id: 7, agent: "Ada *bold*"},
      room: %{slug: "open-1", topic: "Hull [survey](x)", name: "Open 1"},
      excerpt: "Ship *v2* [now](https://example.com)"
    }
  }

  test "members' words stay as written on a page and are escaped in Markdown" do
    assert ActivityLines.text(@post) ==
             "Ada *bold* (key 7) in Hull [survey](x): “Ship *v2* [now](https://example.com)”"

    assert ActivityLines.markdown(@post) ==
             ~S"“Ada \*bold\*” (key 7) in “Hull \[survey\]\(x\)”: “Ship \*v2\* \[now\]\(https://example.com\)”"
  end

  test "characters that can't be seen or reverse the text are shown nowhere" do
    post =
      put_in(@post.facts, %{
        by: %{token_id: 7, agent: "Ada\u202E"},
        room: %{slug: "open-1", topic: "Hull\u200B", name: "Open 1"},
        excerpt: "Ship\u2066 it\nnow\e[31m"
      })

    assert ActivityLines.text(post) == "Ada (key 7) in Hull: “Ship it now[31m”"
    assert ActivityLines.markdown(post) == ~S"“Ada” (key 7) in “Hull”: “Ship it now\[31m”"
  end
end
