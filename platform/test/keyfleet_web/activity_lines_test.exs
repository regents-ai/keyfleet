defmodule KeyfleetWeb.ActivityLinesTest do
  use ExUnit.Case, async: true

  alias KeyfleetWeb.ActivityLines

  # Invariants covered:
  # - a page shows members' words as they wrote them; Markdown escapes every
  #   one of them, so none can act as a link or formatting
  # - neither shows a character that can't be seen or reverses the text
  # - an item whose title has nothing to see still has words to link
  # - a key's number is written the one way every page writes it, and a
  #   proposal is a part of its own, so a page can link it
  # - a payment names its amount as the proposal pages do, and whom it paid;
  #   a symbol a token chose is escaped in Markdown, and its address named

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

  test "an item whose title has nothing to see still has words to link" do
    goal = %{
      id: "created:1",
      at: ~U[2026-09-25 12:00:00Z],
      kind: :created,
      facts: %{by: nil, item: %{id: "goal-1", type: "goal", title: "\u200B\u2066"}}
    }

    assert [{:item, "goal-1", title}] =
             for({:item, _, _} = item <- ActivityLines.parts(goal), do: item)

    assert title != ""
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

  @usdc "0x" <> String.duplicate("e", 40)
  @token "0x" <> String.duplicate("c", 40)
  @recipient "0x12ab" <> String.duplicate("0", 32) <> "cd34"

  test "a payment carried out names its amount and whom it paid" do
    in_usdc = paid(@usdc, {"USDC", 6}, 12_500_000)
    assert ActivityLines.text(in_usdc) == "The fleet paid 12.5 USDC to 0x12ab…cd34 (Proposal 3)."
    assert ActivityLines.markdown(in_usdc) == ActivityLines.text(in_usdc)

    in_token = paid(@token, {"*X*", 2}, 1250)

    assert ActivityLines.text(in_token) ==
             "The fleet paid 12.5 *X* 0xcccc…cccc to 0x12ab…cd34 (Proposal 3)."

    assert ActivityLines.markdown(in_token) ==
             ~S"The fleet paid “12.5 \*X\*” 0xcccc…cccc to 0x12ab…cd34 (Proposal 3)."
  end

  test "a payment put to a vote names its amount and whom it would pay" do
    proposed = %{
      id: "proposal:1",
      at: ~U[2026-09-25 12:00:00Z],
      kind: :proposed,
      facts: %{
        number: 3,
        kind: :pay,
        proposer: %{wallet: @recipient, token_id: 4},
        gist: "Pay the designer",
        launch: nil,
        payment: payment(@usdc, {"USDC", 6}, 12_500_000)
      }
    }

    assert ActivityLines.text(proposed) ==
             "The holder of key 4 put Proposal 3 to a vote to pay 12.5 USDC to 0x12ab…cd34: “Pay the designer”"
  end

  defp paid(asset, details, amount) do
    %{
      id: "executed:1",
      at: ~U[2026-09-25 12:00:00Z],
      kind: :executed,
      facts: %{number: 3, kind: :pay, launch: nil, payment: payment(asset, details, amount)}
    }
  end

  defp payment(asset, details, amount) do
    %{
      asset: asset,
      amount: amount,
      recipient: @recipient,
      assets: %{usdc: @usdc, details: %{asset => details}}
    }
  end
end
