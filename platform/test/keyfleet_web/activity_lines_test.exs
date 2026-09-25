defmodule KeyfleetWeb.ActivityLinesTest do
  use ExUnit.Case, async: true

  alias KeyfleetWeb.ActivityLines

  # Invariants covered:
  # - a page shows members' words as they wrote them; Markdown escapes every
  #   one of them, so none can act as a link or formatting
  # - neither shows a character that can't be seen or reverses the text
  # - a key's number is written the one way every page writes it, and a
  #   proposal is a part of its own, so a page can link it

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

  test "key numbers are grouped, and a proposal is a part a page can link" do
    at = ~U[2026-09-25 12:00:00Z]
    sale = %{id: "sale:1", at: at, kind: :sale, facts: %{token_ids: [1234]}}

    votes = %{
      id: "votes:1",
      at: at,
      kind: :votes,
      facts: %{
        number: 12,
        yes: %{count: 1, token_ids: [1234]},
        no: %{count: 0, token_ids: []}
      }
    }

    assert ActivityLines.text(sale) == "Key 1,234 was bought."
    assert {:proposal, 12} in ActivityLines.parts(votes)
    assert ActivityLines.text(votes) == "Key 1,234 voted yes on Proposal 12."
    assert ActivityLines.markdown(votes) == "Key 1,234 voted yes on Proposal 12."
  end
end
