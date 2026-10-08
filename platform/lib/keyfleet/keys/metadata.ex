defmodule Keyfleet.Keys.Metadata do
  @moduledoc """
  A Key's ERC-721 metadata, as the Key collection's `tokenURI` names it: its
  `baseTokenURI`, `<site>/metadata/keys/`, followed by the Key's token id,
  its fleet's number times 10,000,000,000 plus its Key number; and the
  collection's own, which its `contractURI` names.

  A Key is known once its purchase is recorded. Until its reveal is recorded
  it shows the Interim Keyfleet Access Pass, the same picture for every Key in
  every fleet, and `Status: Revealing`. From then on it shows the traits of
  its card (`Keyfleet.Keys.card_seed/2`) from the fleet's trait table, which change only if an
  operator corrects the reveal by hand after a reorg. While its card is being
  drawn (`Keyfleet.Keys.DrawPicture`) it keeps the pass; once the card is kept
  on IPFS, it shows the card and names its IPFS address in `properties`.
  """

  alias Keyfleet.Fleets
  alias Keyfleet.Fleets.{Fleet, Presets}
  alias Keyfleet.Keys
  alias Keyfleet.Keys.KeyArt
  alias Keyfleet.Traits

  # The Interim Keyfleet Access Pass, kept on IPFS like every key's card
  # (docs/still-pictures/interim-pass).
  @interim_pass_cid "QmddjWKS43UPY3V1muZJGVx8zkpxCUXwmsy29heg1qNETy"

  # The token ids a `tokenURI` can name: the contract's decimal digits, and
  # no more of them than a database integer holds.
  @token_id ~r/\A[1-9][0-9]{0,17}\z/

  @doc "The collection's own metadata (ERC-7572), as its `contractURI` names it."
  def collection(site) do
    %{
      name: "Keyfleet",
      description: "Every Keyfleet Key. A Key is a seat in its fleet.",
      image: picture(nil),
      external_link: site
    }
  end

  @doc """
  The metadata of the Key with token id `token_id`, as the URL gives it:
  `{:revealing, metadata}`, `{:drawing, metadata}` (revealed, its card not
  drawn yet), `{:revealed, metadata}`, or `:not_found` for no recorded Key.
  """
  def for_key(token_id) do
    with true <- token_id =~ @token_id,
         token_id = String.to_integer(token_id),
         %Fleet{} = fleet <- fleet_of(token_id),
         {:ok, number} <- Fleet.key_number(fleet, token_id),
         %{} <- Keys.current_key!(fleet.id, number) do
      key = %{fleet: fleet, token_id: number}

      case Keys.get_reveal!(fleet.id, number) do
        nil -> {:revealing, revealing(key)}
        reveal -> revealed(key, reveal, Keys.get_picture!(reveal.id))
      end
    else
      _unknown -> :not_found
    end
  end

  @doc """
  The picture the metadata of Key `token_id` of the fleet names, and the one
  it will name for a Key not sold yet: the pass until its card is kept on IPFS.
  """
  def image(fleet_id, token_id) do
    case Keys.get_reveal!(fleet_id, token_id) do
      nil -> picture(nil)
      reveal -> reveal.id |> Keys.get_picture!() |> picture()
    end
  end

  defp picture(nil), do: KeyArt.link(@interim_pass_cid)
  defp picture(%{cid: cid}), do: KeyArt.link(cid)

  defp fleet_of(token_id),
    do:
      Enum.find(
        Fleets.list_deployed_fleets!(),
        &match?({:ok, _number}, Fleet.key_number(&1, token_id))
      )

  defp revealing(%{fleet: fleet, token_id: token_id} = key) do
    %{
      name: name(key),
      description:
        "Key #{token_id} of #{fleet.name}. Its traits appear here once they are drawn.",
      image: picture(nil),
      attributes: level(key) ++ [%{trait_type: "Status", value: "Revealing"}]
    }
  end

  defp revealed(key, reveal, nil),
    do: {:drawing, with_traits(key, reveal, picture(nil), %{})}

  defp revealed(key, reveal, %{cid: cid} = kept),
    do: {:revealed, with_traits(key, reveal, picture(kept), %{card: "ipfs://#{cid}"})}

  defp with_traits(%{fleet: fleet, token_id: token_id} = key, reveal, image, card) do
    hash = fleet.trait_table_hash

    traits =
      hash
      |> Traits.table!()
      |> Traits.draw(Keys.card_seed(fleet, reveal))
      |> Enum.map(fn {trait, value} -> %{trait_type: trait, value: value} end)

    %{
      name: name(key),
      description: "Key #{token_id} of #{fleet.name}.",
      image: image,
      attributes: level(key) ++ traits,
      properties: Map.merge(%{seed: reveal.seed, trait_table_hash: hash}, card)
    }
  end

  defp name(%{fleet: fleet, token_id: token_id}), do: Fleets.key_name(fleet.id, token_id)

  defp level(%{fleet: fleet, token_id: token_id}) do
    if Presets.levelled?(fleet.id),
      do: [%{trait_type: "Level", value: Presets.fibonacci_level_of(token_id)}],
      else: []
  end
end
