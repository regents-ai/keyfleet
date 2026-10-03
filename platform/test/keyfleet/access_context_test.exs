defmodule Keyfleet.AccessContextTest do
  use ExUnit.Case, async: true

  alias Keyfleet.AccessContext
  alias Keyfleet.AccessContext.AccountControl

  @wallet "0x1111111111111111111111111111111111111111"

  test "anonymous account control exposes only sign in" do
    assert AccessContext.account_control(AccessContext.for_account(nil)) ==
             %AccountControl{kind: :sign_in, label: "Sign In", avatar_src: nil}
  end

  test "a signed human is named by their display name and drawn from their wallet" do
    account = %{wallet_address: @wallet, display_name: "Account label"}

    assert %AccountControl{
             kind: :signed_in,
             label: "Account label",
             avatar_src: "data:image/svg+xml;base64," <> _
           } = AccessContext.account_control(AccessContext.for_account(account))
  end

  test "a signed human without a display name is named by their shortened wallet" do
    account = %{wallet_address: @wallet, display_name: nil}

    assert %AccountControl{kind: :signed_in, label: "0x1111..1111"} =
             AccessContext.account_control(AccessContext.for_account(account))
  end
end
