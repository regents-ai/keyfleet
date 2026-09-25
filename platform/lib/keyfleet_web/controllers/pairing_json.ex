defmodule KeyfleetWeb.PairingJSON do
  @moduledoc "How a pairing's parts read to the agent it pairs."

  @doc """
  What the owner allows the agent to commit to on this key; an agent holding
  its own key has no limits written.
  """
  def limits(%{limits_written_at: nil}), do: nil

  def limits(pairing) do
    %{
      money: pairing.limits_money,
      your_information: pairing.limits_information,
      outside_keyfleet: pairing.limits_outside,
      check_with_owner_first: pairing.limits_check_first,
      written_at: pairing.limits_written_at
    }
  end
end
