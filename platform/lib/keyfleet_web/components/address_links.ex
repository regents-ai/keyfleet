defmodule KeyfleetWeb.Components.AddressLinks do
  @moduledoc """
  What a person can do with a wallet address shown on a page: copy it in
  full, or open it on OpenSea or Basescan. The site builds both links from the
  address it holds; nothing a visitor sends reaches them.
  """
  use KeyfleetWeb, :html

  @doc "The address's page on Basescan."
  def basescan(address), do: "https://basescan.org/address/#{address}"

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
        aria-label="Copy the wallet address"
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
