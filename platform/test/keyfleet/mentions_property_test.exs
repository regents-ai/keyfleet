defmodule Keyfleet.MentionsPropertyTest do
  # Any post yields exactly the different Keys it names as `@Key N`, at most
  # 20, and no post, however hostile, breaks the reading or the page.
  use ExUnit.Case, async: true
  use ExUnitProperties

  import Phoenix.HTML, only: [safe_to_string: 1]

  alias Keyfleet.Rooms.Mentions
  alias KeyfleetWeb.RoomsLive

  @hostile [
    "<script>alert(1)</script>",
    ~s{<img src=x onerror="alert(1)">},
    "[x](javascript:alert(1))",
    ~s{"><svg onload=alert(1)>},
    "<a href=\"data:text/html,1\">x</a>",
    "**",
    "`",
    "[",
    "](",
    "\\",
    "\n\n",
    "a@",
    "@@",
    "@Key",
    "@Key ",
    "@Key 0",
    "&amp;",
    "@Key 99999999999999999999999"
  ]

  property "a post yields the different Keys it names, in order, at most 20" do
    check all(pieces <- list_of(piece(), max_length: 60)) do
      body = Enum.map_join(pieces, " ", &written/1)
      named = for {:mention, n, _style} <- pieces, uniq: true, do: n

      assert Mentions.parse(body) == Enum.take(named, 20)
    end
  end

  property "any words read without failing, as at most 20 different Keys" do
    check all(body <- one_of([string(:printable), string(:utf8), hostile_body()])) do
      keys = Mentions.parse(body)

      assert length(keys) <= 20
      assert Enum.uniq(keys) == keys
      assert Enum.all?(keys, &(&1 in 1..9_223_372_036_854_775_807))
    end
  end

  property "a hostile post never shows a tag, handler or address it wasn't allowed" do
    check all(body <- hostile_body(), max_runs: 200) do
      html = body |> RoomsLive.body_html("fibonacci_syndicate") |> safe_to_string()

      refute html =~ ~r/<(script|img|svg|iframe)/i
      refute html =~ ~r/<[a-z][^>]*[\s\/]on\w+\s*=/i

      for [href] <- Regex.scan(~r/<a href="([^"]*)"/, html, capture: :all_but_first),
          do: assert(href =~ ~r/\A(https?:|mailto:)/)
    end
  end

  # A Key named in one of the ways the rule allows, or words that name none
  # whatever stands beside them.
  defp piece do
    one_of([
      tuple({constant(:mention), integer(1..200), member_of([:spaced, :joined, :lower, :upper])}),
      map(string(:alphanumeric, max_length: 12), &{:text, &1}),
      map(member_of(["@Key x", "@ Key 2", "key 3", "a@Key 4", "Key 5", "@Key 0"]), &{:text, &1})
    ])
  end

  defp written({:mention, n, :spaced}), do: "@Key #{n}"
  defp written({:mention, n, :joined}), do: "@Key#{n}"
  defp written({:mention, n, :lower}), do: "@key #{n}"
  defp written({:mention, n, :upper}), do: "@KEY#{n}"
  defp written({:text, words}), do: words

  defp hostile_body do
    gen all(
          parts <-
            list_of(
              one_of([
                member_of(@hostile),
                map(integer(1..99), &"@Key #{&1}"),
                string(:printable, max_length: 8)
              ]),
              max_length: 20
            )
        ) do
      Enum.join(parts)
    end
  end
end
