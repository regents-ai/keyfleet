defmodule Keyfleet.WalletSteps.Steps do
  @moduledoc """
  One group of wallet buttons' steps, built for a signer as
  `Keyfleet.WalletSteps.Build` describes.

  Only a signed-in person may build steps, and only for a wallet their
  account links: the signer is checked against the actor's own wallets, never
  taken from the page on trust.
  """
  use Ash.Resource,
    domain: Keyfleet.WalletSteps,
    authorizers: [Ash.Policy.Authorizer]

  @flows [
    :buy,
    :claim,
    :vote,
    :carry_out,
    :collect,
    :propose_decision,
    :propose_payment,
    :propose_launch,
    :delegate,
    :send_share
  ]

  actions do
    action :build, :map do
      description "The steps one group of wallet buttons sends, for one signer."
      argument :fleet_id, :string, allow_nil?: false
      argument :flow, :atom, allow_nil?: false, constraints: [one_of: @flows]

      argument :signer, :string,
        allow_nil?: false,
        constraints: [match: ~r/\A0x[0-9a-fA-F]{40}\z/]

      argument :component_id, :string, allow_nil?: false

      argument :inputs, :map,
        allow_nil?: false,
        default: %{},
        description: "The form's values as the page shows them, as strings."

      argument :proposal, :integer, constraints: [min: 1]
      argument :token_id, :integer, constraints: [min: 1]

      validate present(:proposal), where: argument_in(:flow, [:vote, :carry_out, :collect])
      validate present(:token_id), where: argument_in(:flow, [:claim])
      run Keyfleet.WalletSteps.Build
    end
  end

  policies do
    policy action(:build) do
      authorize_if Keyfleet.WalletSteps.LinkedSigner
    end
  end
end
