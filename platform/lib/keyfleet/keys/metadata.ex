defmodule Keyfleet.Keys.Metadata do
  @moduledoc """
  A key's ERC-721 metadata, as each fleet's `tokenURI` names it: the fleet's
  `baseTokenURI`, `<site>/metadata/<slot>/`, followed by the key's number.

  A key is known once its purchase is recorded. Until its reveal is recorded
  it shows the Interim KeyFleet Access Pass, the same picture for every key in
  every fleet, and `Status: Revealing`; from then on
  it shows the traits drawn from its seed with the fleet's trait table, which
  change only if an operator corrects the reveal by hand after a reorg.
  """

  alias Keyfleet.Fleets
  alias Keyfleet.Fleets.Presets
  alias Keyfleet.Keys
  alias Keyfleet.Traits

  # The key numbers a `tokenURI` can name: the contract's decimal digits, and
  # no more of them than a database integer holds.
  @token_id ~r/\A[1-9][0-9]{0,17}\z/

  @doc """
  The metadata of the key numbered `token_id` in the fleet at deployment
  `slot`, both as the URL gives them, with its pictures under `site_url`:
  `{:revealing, metadata}`, `{:revealed, metadata}`, or `:not_found` for no
  such slot or no recorded key.
  """
  def for_key(slot, token_id, site_url) do
    with fleet_id when is_binary(fleet_id) <- Fleets.slot_fleet_id(slot),
         true <- token_id =~ @token_id,
         token_id = String.to_integer(token_id),
         %{} <- Keys.current_key!(fleet_id, token_id) do
      fleet = Fleets.get_fleet!(fleet_id)
      key = %{fleet: fleet, slot: slot, token_id: token_id, site_url: site_url}

      case Keys.get_reveal!(fleet_id, token_id) do
        nil -> {:revealing, revealing(key)}
        reveal -> {:revealed, revealed(key, reveal)}
      end
    else
      _unknown -> :not_found
    end
  end

  defp revealing(%{fleet: fleet, token_id: token_id, site_url: site_url} = key) do
    %{
      name: name(key),
      description:
        "Key #{token_id} of #{fleet.name}. Its traits appear here once they are drawn.",
      image: "#{site_url}/images/keys/interim-keyfleet-access-pass.png",
      attributes: level(key) ++ [%{trait_type: "Status", value: "Revealing"}]
    }
  end

  defp revealed(%{fleet: fleet, slot: slot, token_id: token_id, site_url: site_url} = key, reveal) do
    hash = fleet.trait_table_hash

    traits =
      hash
      |> Traits.table!()
      |> Traits.draw(reveal.seed)
      |> Enum.map(fn {trait, value} -> %{trait_type: trait, value: value} end)

    %{
      name: name(key),
      description: "Key #{token_id} of #{fleet.name}.",
      image: "#{site_url}/art/#{hash}/#{slot}/#{token_id}.png",
      attributes: level(key) ++ traits,
      properties: %{seed: reveal.seed, trait_table_hash: hash}
    }
  end

  defp name(%{fleet: fleet, token_id: token_id}), do: "#{fleet.name} ##{token_id}"

  defp level(%{fleet: fleet, token_id: token_id}) do
    if Presets.levelled?(fleet.id),
      do: [%{trait_type: "Level", value: Presets.fibonacci_level_of(token_id)}],
      else: []
  end
end
