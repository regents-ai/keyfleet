defmodule Keyfleet.AuthorityTest do
  use ExUnit.Case, async: true

  alias Keyfleet.Authority

  test "while the site is closed only public rows say open; once open, every row does but one closed for its own reason" do
    closed = Authority.markdown_table(false)
    open = Authority.markdown_table(true)

    for row <- Authority.rows() do
      line = "| #{row.what} | #{row.who} |"

      {when_closed, when_open} =
        case row do
          %{closed: reason} -> {"| Closed: #{reason} |", "| Closed: #{reason} |"}
          %{authority: :public} -> {"| Open |", "| Open |"}
          _gated -> {"| Closed: opens at launch |", "| Open |"}
        end

      assert closed |> String.split("\n") |> Enum.find(&String.starts_with?(&1, line)) =~
               when_closed

      assert open |> String.split("\n") |> Enum.find(&String.starts_with?(&1, line)) =~ when_open
    end
  end
end
