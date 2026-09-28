defmodule Keyfleet.EarlyTest do
  use ExUnit.Case, async: true

  alias Keyfleet.Actors.System
  alias Keyfleet.Early
  alias Keyfleet.Early.Signup

  setup do
    Ecto.Adapters.SQL.Sandbox.checkout(Keyfleet.Repo)
  end

  test "an address is kept trimmed and lowercased" do
    assert {:ok, _signup} = Early.sign_up("  Ada@Example.COM \n")

    assert [%Signup{email: "ada@example.com", inserted_at: %DateTime{}}] = list()
  end

  test "leaving an address already on the list changes nothing" do
    Early.sign_up!("ada@example.com")
    [first] = list()

    assert {:ok, _signup} = Early.sign_up("ADA@example.com")
    assert {:ok, _signup} = Early.sign_up(" ada@example.com")

    assert list() == [first]
  end

  test "an address that can't be an email is refused and nothing is kept" do
    too_long = String.duplicate("a", 243) <> "@example.com"
    # 134 letters, but 256 bytes.
    too_many_bytes = String.duplicate("é", 122) <> "@example.com"

    for address <-
          ["", "   ", "ada", "ada@example", "@example.com", "ada@", "ada@@example.com"] ++
            ["ada lovelace@example.com", "ada@exa mple.com", "ada@example.com\tx"] ++
            [too_long, too_many_bytes] do
      assert {:error, %Ash.Error.Invalid{}} = Early.sign_up(address), inspect(address)
    end

    assert list() == []
  end

  test "an address of exactly 254 bytes fits" do
    address = String.duplicate("a", 242) <> "@example.com"
    assert byte_size(address) == 254

    assert {:ok, _signup} = Early.sign_up(address)
  end

  test "only the system reads the list" do
    Early.sign_up!("ada@example.com")

    assert {:error, %Ash.Error.Forbidden{}} = Ash.read(Signup)
    assert {:ok, [_signup]} = Ash.read(Signup, actor: %System{})
  end

  defp list, do: Ash.read!(Signup, actor: %System{})
end
