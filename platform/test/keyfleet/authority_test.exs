defmodule Keyfleet.AuthorityTest do
  use ExUnit.Case, async: true

  alias Keyfleet.Authority

  test "while the site is closed only public rows say open; once open, every row does" do
    closed = Authority.markdown_table(false)
    open = Authority.markdown_table(true)

    for row <- Authority.rows() do
      line = "| #{row.what} | #{row.who} |"

      {when_closed, when_open} =
        case row do
          %{authority: :public} -> {"| Open |", "| Open |"}
          _gated -> {"| Closed: opens at launch |", "| Open |"}
        end

      assert closed |> String.split("\n") |> Enum.find(&String.starts_with?(&1, line)) =~
               when_closed

      assert open |> String.split("\n") |> Enum.find(&String.starts_with?(&1, line)) =~ when_open
    end
  end

  test "the treasury page lists every wallet permission but buying a Key" do
    assert Enum.map(Authority.treasury_rows(), & &1.what) ==
             for(
               %{authority: :wallet, what: what} <- Authority.rows(),
               what != "Buy a Key",
               do: what
             )
  end
end
