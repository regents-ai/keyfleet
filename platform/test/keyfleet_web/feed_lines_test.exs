defmodule KeyfleetWeb.FeedLinesTest do
  use ExUnit.Case, async: true

  alias KeyfleetWeb.FeedLines

  # Invariants covered:
  # - transfers next to each other to one wallet, each within ten minutes of
  #   the one after it, are one line, named for the oldest and timed by the
  #   newest
  # - another wallet, a longer gap or another item between them starts a
  #   line of its own
  # - two pages joined where they meet read as one page would
  # - a fresh first page leaves the newer part of a run on show below it

  @now ~U[2026-11-11 12:00:00Z]
  @heir "0x" <> String.duplicate("3", 40)
  @other "0x" <> String.duplicate("4", 40)

  test "transfers to one wallet within the window are one line" do
    items = [transfer(4, 7, 0), transfer(3, 4, 300), transfer(2, 3, 540)]

    assert [line] = FeedLines.lines(items, receivers(items, @heir))

    assert line == %{
             id: "transfer:2",
             at: at(0),
             since: at(540),
             kind: :moved,
             facts: %{token_ids: [3, 4, 7], to: @heir}
           }
  end

  test "another wallet, a longer gap or an item between starts a line of its own" do
    to_other = transfer(5, 9, 0)
    late = transfer(4, 7, 60)
    gap = transfer(3, 4, 60 + 601)
    sale = %{id: "sale:2", at: at(700), kind: :sale, facts: %{token_ids: [8]}}
    before = transfer(1, 3, 710)
    items = [to_other, late, gap, sale, before]
    receivers = %{receivers(items, @heir) | "transfer:5" => @other}

    assert [
             %{id: "transfer:5", facts: %{token_ids: [9], to: @other}},
             %{id: "transfer:4", facts: %{token_ids: [7]}},
             %{id: "transfer:3", facts: %{token_ids: [4]}},
             ^sale,
             %{id: "transfer:1", facts: %{token_ids: [3]}}
           ] = FeedLines.lines(items, receivers)
  end

  test "the window runs from one transfer to the next, so a run outlasts it" do
    items = for n <- 4..1//-1, do: transfer(n, n, (4 - n) * 500)

    assert [%{id: "transfer:1", since: since, at: newest, facts: %{token_ids: [1, 2, 3, 4]}}] =
             FeedLines.lines(items, receivers(items, @heir))

    assert DateTime.diff(newest, since) == 1_500
  end

  test "a run cut by a page's end joins up again under the line above it" do
    items = for n <- 6..1//-1, do: transfer(n, n, 6 - n)
    {top, bottom} = Enum.split(items, 3)
    [above] = FeedLines.lines(top, receivers(top, @heir))

    assert {:joined, [joined]} =
             FeedLines.join(above, FeedLines.lines(bottom, receivers(bottom, @heir)))

    assert [joined] == FeedLines.lines(items, receivers(items, @heir))

    other = transfer(0, 9, 7)

    assert {:apart, [%{id: "transfer:0"}]} =
             FeedLines.join(above, FeedLines.lines([other], %{"transfer:0" => @other}))

    assert {:apart, []} = FeedLines.join(above, [])
  end

  test "a first page drawn over earlier pages leaves a run they show below it" do
    post = %{id: "post:1", at: at(0), kind: :post, facts: %{}}
    items = [post, transfer(4, 4, 1), transfer(3, 3, 2)]
    lines = FeedLines.lines(items, receivers(items, @heir))

    assert FeedLines.over(lines, MapSet.new(["post:1", "transfer:1"])) == [post]
    assert FeedLines.over(lines, MapSet.new(["post:1", "transfer:3"])) == lines
  end

  # Transfer number `seq`, Key `token_id` moved `ago` seconds before now.
  defp transfer(seq, token_id, ago),
    do: %{id: "transfer:#{seq}", at: at(ago), kind: :transfer, facts: %{token_id: token_id}}

  defp at(ago), do: DateTime.add(@now, -ago)

  defp receivers(items, wallet), do: Map.new(items, &{&1.id, wallet})
end
