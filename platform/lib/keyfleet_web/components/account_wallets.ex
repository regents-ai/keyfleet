defmodule KeyfleetWeb.AccountWallets do
  @moduledoc """
  The signed-in person's wallets, in the side panel and on the Account page:
  each one's address with its copy icon and Basescan arrow
  (`Regent.Primitives.address`), what it is, and which one is active.

  The wallets are the ones the account's sign-in verified, its own wallet first.
  Which of them Privy made at sign-in (the Regents wallet) and which one is active
  are the browser's to know, so the `AccountWallets` hook reports both when the
  page arrives and each time the wallet changes. Until it does, each wallet is
  said to be linked to this account, with no Active mark. A wallet the account
  isn't linked to, such as a wallet app left connected from before a Google
  sign-in, is never shown or marked.

  The parent passes `account` (the signed-in account) and `id`.
  """
  use KeyfleetWeb, :live_component

  alias KeyfleetWeb.OnchainSteps

  @impl true
  def mount(socket), do: {:ok, assign(socket, active: nil, regents: nil)}

  @impl true
  def update(%{account: account, id: id} = assigns, socket),
    do:
      {:ok,
       assign(socket,
         id: id,
         class: assigns[:class],
         linked: linked(account)
       )}

  @impl true
  def handle_event("wallets_seen", %{"active" => active, "regents" => regents}, socket),
    do:
      {:noreply,
       assign(socket,
         active: OnchainSteps.active_wallet(%{"address" => active}),
         regents: regents_wallets(regents)
       )}

  @impl true
  def render(assigns) do
    assigns = assign(assigns, rows: rows(assigns.linked, assigns.active, assigns.regents))

    ~H"""
    <section
      id={@id}
      class={["account-wallets", @class]}
      phx-hook="AccountWallets"
      aria-labelledby={"#{@id}-title"}
    >
      <h2 id={"#{@id}-title"}>{if length(@rows) == 1, do: "Wallet", else: "Wallets"}</h2>
      <ul class="account-wallets__list">
        <li
          :for={row <- @rows}
          id={"#{@id}-#{row.address}"}
          class="account-wallets__row"
          data-active={row.active?}
        >
          <span class="account-wallets__label">{row.label}</span>
          <Regent.Primitives.address id={"#{@id}-#{row.address}-address"} address={row.address} />
          <Regent.Primitives.status :if={row.active?} tone="success">Active</Regent.Primitives.status>
        </li>
      </ul>
    </section>
    """
  end

  @doc """
  The rows shown: the account's wallets in order, the active one marked. Each says
  what it is once the browser has said which wallet is the Regents wallet
  (`regents`, `nil` until then).
  """
  def rows(linked, active, regents) do
    Enum.map(linked, fn address ->
      %{address: address, active?: address == active, label: label(address, regents)}
    end)
  end

  defp label(_address, nil), do: "Linked to this account"

  defp label(address, regents),
    do: if(address in regents, do: "Regents wallet", else: "Your wallet")

  defp linked(%{wallet_address: own, wallet_addresses: wallets}),
    do:
      [own | List.wrap(wallets)]
      |> Enum.reject(&is_nil/1)
      |> Enum.map(&String.downcase/1)
      |> Enum.uniq()

  defp regents_wallets(addresses) when is_list(addresses),
    do: Enum.flat_map(addresses, &List.wrap(OnchainSteps.active_wallet(%{"address" => &1})))

  defp regents_wallets(_unknown), do: nil
end
