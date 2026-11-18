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

  # Costly failure: a character drawn as nothing or as a blank is kept inside
  # an address, so one person is on the list twice and the kept address may
  # never reach them.
  test "an address holding anything but letters, marks, digits and address punctuation is refused" do
    # A Braille blank, an interlinear anchor, an Egyptian joiner, a Hangul
    # filler (a letter), a variation selector (a mark) and a bracket.
    for cp <- [0x2800, 0xFFF9, 0x13430, 0x3164, 0xFE0F, ?[],
        typed <- [
          <<cp::utf8>> <> "ada@example.com",
          "ada" <> <<cp::utf8>> <> "@example.com",
          "ada@exa" <> <<cp::utf8>> <> "mple.com",
          "ada@example.com" <> <<cp::utf8>>
        ] do
      assert {:error, %Ash.Error.Invalid{}} = Early.sign_up(typed), inspect(typed)
    end

    assert {:error, %Ash.Error.Invalid{}} = Early.sign_up("ada@[192.0.2.1]")
    assert list() == []
  end

  test "an ordinary address in any script is kept, and so is every punctuation mark an address takes" do
    typed = [
      "first.last+tag@sub.example.co.uk",
      "a!#$%&'*+-/=?^_`{|}~b@example.com",
      "josé@exámple.es",
      "иван@пример.испытание",
      "مستخدم@مثال.إختبار",
      "משתמש@דוגמה.ישראל",
      "कुमार@उदाहरण.भारत",
      "สมชาย@ตัวอย่าง.ไทย",
      "用户@例子.中国",
      "ユーザー@例え.テスト",
      "사용자@예시.한국",
      "jordi@col·legi.cat",
      "ada@mail。example.com"
    ]

    for address <- typed, do: assert({:ok, _signup} = Early.sign_up(address), address)

    assert length(list()) == length(typed)
  end

  # A host typed on a Japanese or Chinese keyboard may hold these dots, and is
  # kept with the plain one; before the @ they are not an address.
  test "the host's three other dots are taken after the @ only" do
    for cp <- [0x3002, 0xFF0E, 0xFF61] do
      before = "ada" <> <<cp::utf8>> <> "lovelace@example.com"
      assert {:error, %Ash.Error.Invalid{}} = Early.sign_up(before), inspect(before)
      assert {:ok, _signup} = Early.sign_up("ada@mail" <> <<cp::utf8>> <> "example.com")
    end

    assert [%Signup{email: "ada@mail.example.com"}] = list()
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
