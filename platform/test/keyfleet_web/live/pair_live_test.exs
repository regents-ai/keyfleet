defmodule KeyfleetWeb.PairLiveTest do
  # A pairing link's page is printed as a link and pasted to an agent, so only a
  # page on this site is taken; anything a browser could read as another site is
  # dropped and the link opens plain pairing.
  use ExUnit.Case, async: true

  alias KeyfleetWeb.PairLive

  test "a page on this site is where the agent starts" do
    for to <- ["/", "/classic/1", "/classic/1/workspace?project=virtual-cell&place=docs#goals"],
        do: assert(PairLive.start(%{"to" => to}) == to)
  end

  test "anything else opens plain pairing" do
    for to <- [
          "//example.com",
          "/\\example.com",
          "https://example.com/classic/1",
          "javascript:alert(1)",
          "classic/1",
          "/classic 1",
          "/classic\n1",
          "/classic\u0000",
          "",
          "/" <> String.duplicate("a", 512),
          ["/classic/1"]
        ],
        do: assert(PairLive.start(%{"to" => to}) == nil, inspect(to))

    assert PairLive.start(%{}) == nil
  end
end
