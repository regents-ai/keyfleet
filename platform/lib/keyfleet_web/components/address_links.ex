defmodule KeyfleetWeb.Components.AddressLinks do
  @moduledoc """
  What a person can do with a wallet address shown on a page: copy it in
  full, or open it on OpenSea or Basescan; and a transaction's page on
  Basescan. The site builds every link from the address or hash it holds;
  nothing a visitor sends reaches them.
  """
  use KeyfleetWeb, :html

  @doc "The address's page on Basescan."
  def basescan(address), do: "https://basescan.org/address/#{address}"

  @doc "The transaction's page on Basescan."
  def basescan_tx(hash), do: "https://basescan.org/tx/#{hash}"

  @doc "The address's profile on OpenSea."
  def opensea(address), do: "https://opensea.io/#{address}"

  attr :id, :string, required: true
  attr :address, :string, required: true

  def address_links(assigns) do
    ~H"""
    <span id={@id} class="address-links">
      <Regent.Primitives.copy_button
        id={"#{@id}-copy"}
        variant="quiet"
        text={@address}
        aria-label="Copy address"
      >
        Copy address
      </Regent.Primitives.copy_button>
      <a id={"#{@id}-opensea"} href={opensea(@address)} rel="noopener noreferrer" target="_blank">
        OpenSea
      </a>
      <a id={"#{@id}-basescan"} href={basescan(@address)} rel="noopener noreferrer" target="_blank">
        Basescan
      </a>
    </span>
    """
  end
end
