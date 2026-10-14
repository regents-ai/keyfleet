defmodule KeyfleetWeb.TreasuryController do
  @moduledoc "Public treasury figures shared with the fleet page; no wallet authority."
  use KeyfleetWeb, :controller

  def show(conn, %{"fleet_id" => fleet_id}) do
    conn = put_resp_header(conn, "cache-control", "no-store")

    if fleet_id in Keyfleet.Fleets.open_fleet_ids() do
      case KeyfleetWeb.PageRead.run("treasury", fn ->
             KeyfleetWeb.ProposalsPage.treasury_page(fleet_id)
           end) do
        {:ok, page} -> present(conn, fleet_id, page)
        {:error, _failure} -> KeyfleetWeb.Refusal.json(conn, 503, "treasury_unavailable")
      end
    else
      KeyfleetWeb.Refusal.json(conn, 404, "fleet_unknown")
    end
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
