defmodule KeyfleetWeb.TreasuryController do
  @moduledoc "Public treasury figures shared with the fleet page; no wallet authority."
  use KeyfleetWeb, :controller

  # A fleet that isn't open has no treasury to show; one that can't be read
  # is unavailable for now.
  def show(conn, %{"fleet_id" => fleet_id}) do
    conn = put_resp_header(conn, "cache-control", "no-store")

    case KeyfleetWeb.PageRead.run("treasury", fn -> treasury(fleet_id) end) do
      {:ok, nil} -> KeyfleetWeb.Refusal.json(conn, 404, "fleet_unknown")
      {:ok, page} -> present(conn, fleet_id, page)
      {:error, _failure} -> KeyfleetWeb.Refusal.json(conn, 503, "treasury_unavailable")
    end
  end

  defp treasury(fleet_id) do
    if fleet_id in Keyfleet.Fleets.open_fleet_ids(),
      do: KeyfleetWeb.ProposalsPage.treasury_page(fleet_id)
  end

  defp present(conn, fleet_id, page) do
    json(conn, %{
      fleet_id: fleet_id,
      chain_id: page.chain_id,
      catching_up: page.catching_up?,
      deployed: page.deployed?,
      treasury: page.treasury,
      manager_address: page.manager_address,
      manager_explorer: explorer(page.manager_address),
      treasury_explorer: if(page.treasury, do: explorer(page.treasury.address)),
      balance_meaning:
        "held is in the treasury; backed is held separately in the rewards contract",
      permissions: Keyfleet.Authority.treasury_rows(),
      proposals_url: KeyfleetWeb.ProposalsPage.list_path(fleet_id)
    })
  end

  defp explorer(nil), do: nil
  defp explorer(address), do: KeyfleetWeb.Components.AddressLinks.basescan(address)
end
