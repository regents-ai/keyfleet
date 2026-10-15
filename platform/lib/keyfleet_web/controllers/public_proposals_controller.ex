defmodule KeyfleetWeb.PublicProposalsController do
  @moduledoc "Public indexed proposal discovery using the human list's existing read."
  use KeyfleetWeb, :controller

  alias Keyfleet.{Chain, Fleets, Proposals}
  alias KeyfleetWeb.{PageRead, ProposalJSON, Refusal}

  def index(conn, _params) do
    conn = conn |> fetch_query_params() |> put_resp_header("cache-control", "no-store")
    fleet_id = conn.path_params["fleet_id"]

    case cursor(conn.query_params) do
      {:ok, before} ->
        case PageRead.run("proposals", fn -> listing(fleet_id, before) end) do
          {:ok, :unknown} -> Refusal.json(conn, 404, "fleet_unknown")
          {:ok, result} -> json(conn, result)
          {:error, _} -> Refusal.json(conn, 503, "proposals_unavailable")
        end

      :error ->
        Refusal.json(conn, 400, "invalid_proposal_cursor")
    end
  end

  defp cursor(params) when map_size(params) == 0, do: {:ok, nil}

  defp cursor(%{"before" => value} = params) when map_size(params) == 1 and is_binary(value) do
    if Regex.match?(~r/\A[1-9][0-9]{0,18}\z/, value) and
         String.to_integer(value) <= 9_223_372_036_854_775_807,
       do: {:ok, String.to_integer(value)},
       else: :error
  end

  defp cursor(_params), do: :error

  defp listing(fleet_id, before) do
    if fleet_id in Fleets.open_fleet_ids() do
      fleet = Fleets.get_fleet!(fleet_id)
      {proposals, more?} = Proposals.list_page(fleet_id, before)
      deployed? = fleet.manager_address != nil

      %{
        fleet_id: fleet_id,
        deployed: deployed?,
        catching_up: deployed? and not Chain.fresh?(fleet_id),
        source: "indexed",
        generated_at: DateTime.utc_now(),
        proposals: Enum.map(proposals, &ProposalJSON.list_item/1),
        next_before: if(more?, do: Integer.to_string(List.last(proposals).number))
      }
    else
      :unknown
    end
  end
end
