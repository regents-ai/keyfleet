defmodule Keyfleet.Keys.Metadata do
  @moduledoc """
  A Key's ERC-721 metadata, as the Key collection's `tokenURI` names it: its
  `baseTokenURI`, `<site>/metadata/keys/`, followed by the Key's token id,
  its fleet's number times 10,000,000,000 plus its Key number; and the
  collection's own, which its `contractURI` names.

  A Key is known once its mint is recorded. A Key within its fleet's deck has
  its card from then on; a later Key shows the Interim Keyfleet Access Pass,
  the same picture for every Key in every fleet, and `Status: Revealing` until
  its reveal is recorded. A Key with its card (`Keyfleet.Keys.card_seed/2`)
  shows the card's traits from the fleet's trait table, which change only if
  an operator corrects a reveal by hand after a reorg. While its card is being
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
      image: site |> URI.merge("/favicon-192.png") |> URI.to_string(),
      external_link: site
    }
  end

  @doc """
  The metadata of the Key with token id `token_id`, as the URL gives it:
  `{:revealing, metadata}`, `{:drawing, metadata}` (its card known, not
  drawn yet), `{:revealed, metadata}`, or `:not_found` for no recorded Key.
  """
  def for_key(token_id) do
    with true <- token_id =~ @token_id,
         token_id = String.to_integer(token_id),
         %Fleet{} = fleet <- fleet_of(token_id),
         {:ok, number} <- Fleet.key_number(fleet, token_id),
         %{} <- Keys.current_key!(fleet.id, number) do
      key = %{fleet: fleet, token_id: number}

      case Keys.card_seed(fleet, number) do
        nil -> {:revealing, revealing(key)}
        seed -> revealed(key, seed, Keys.get_picture!(fleet.id, number, seed))
      end
    else
      _unknown -> :not_found
    end
  end

  @doc """
  The picture the metadata of minted Key `token_id` of `fleet` names: the
  pass until its card is kept on IPFS, then the card.
  """
  def image(fleet, token_id) do
    case Keys.card_seed(fleet, token_id) do
      nil -> picture(nil)
      seed -> picture(Keys.get_picture!(fleet.id, token_id, seed))
    end
  end

  @doc """
  Where the close-up of each of the minted Keys `token_ids` of `fleet` is
  shown, by Key number, for the Keys whose card has one, in two reads however
  many Keys are asked for, a hundred at most. A Key still waiting for its
  card or its close-up is left out.
  """
  def close_ups(fleet, token_ids), do: small_pictures(fleet, token_ids, :close_up_cid)

  @doc """
  Where the small card of each of the minted Keys `token_ids` of `fleet` is
  shown, as `close_ups/2` answers for close-ups.
  """
  def small_cards(fleet, token_ids), do: small_pictures(fleet, token_ids, :small_card_cid)

  defp small_pictures(fleet, token_ids, field) do
    seeds = Keys.card_seeds(fleet, token_ids)

    for kept <- Keys.pictures_of_keys!(fleet.id, Map.keys(seeds)),
        cid = Map.fetch!(kept, field),
        is_binary(cid) and seeds[kept.token_id] == kept.seed,
        into: %{},
        do: {kept.token_id, KeyArt.link(cid)}
  end

  @doc "The picture a Key not minted yet shows: the pass."
  def pass, do: picture(nil)

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
      attributes: set(key) ++ level(key) ++ [%{trait_type: "Status", value: "Revealing"}]
    }
  end

  defp revealed(key, seed, nil),
    do: {:drawing, with_traits(key, seed, picture(nil), %{})}

  defp revealed(key, seed, %{cid: cid} = kept),
    do: {:revealed, with_traits(key, seed, picture(kept), %{card: "ipfs://#{cid}"})}

  defp with_traits(%{fleet: fleet, token_id: token_id} = key, seed, image, card) do
    hash = fleet.trait_table_hash

    traits =
      hash
      |> Traits.table!()
      |> Traits.draw(seed)
      |> Enum.map(fn {trait, value} -> %{trait_type: trait, value: value} end)

    %{
      name: name(key),
      description: "Key #{token_id} of #{fleet.name}.",
      image: image,
      attributes: set(key) ++ level(key) ++ traits,
      properties: Map.merge(%{seed: seed, trait_table_hash: hash}, card)
    }
  end

  defp name(%{fleet: fleet, token_id: token_id}), do: Fleets.key_name(fleet.id, token_id)

  @doc "The fleet's `Set Type` trait, such as \"Regents Club\", as every one of its Keys shows it."
  def set_type(fleet_id) do
    %{card: type} = Enum.find(Fleets.catalog(), &(&1.id == fleet_id))
    type |> String.split() |> Enum.map_join(" ", &String.capitalize/1)
  end

  defp set(%{fleet: fleet}) do
    %{type_number: number} = Enum.find(Fleets.catalog(), &(&1.id == fleet.id))

    # The fixed catalog accepts only founding fleets (typeNumber 1), each the
    # first set of its own type. chain_fleet_id numbers all types together.
    [
      %{trait_type: "Set Type", value: set_type(fleet.id)},
      %{trait_type: "Set ID", value: number |> Integer.to_string() |> String.pad_leading(3, "0")}
    ]
  end

  defp level(%{fleet: fleet, token_id: token_id}) do
    if Presets.levelled?(fleet.id),
      do: [%{trait_type: "Level", value: Presets.fibonacci_level_of(token_id)}],
      else: []
  end
end
