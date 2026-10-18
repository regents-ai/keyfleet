defmodule KeyfleetWeb.NotebookOpenController do
  @moduledoc """
  Opens a fleet's notebooks for the person signed in here, landing on `to`:
  the notebooks' start page or a saved output
  (`Keyfleet.Notebooks.destination?/1`). A holder's browser is handed a
  page that sends a code that works once to the fleet's notebook host
  (`KeyfleetWeb.NotebookOpenHTML`); the host spends a code only when this
  site's page sends it. A saved output's address sends
  someone without a notebook sign-in here (`KeyfleetWeb.Plugs.NotebookGateway`);
  a holder of one of the fleet's keys goes back to it the same way, and anyone else lands on the fleet's workspace with a note saying why.
  Key ownership that can't be read, other than while it is being brought up
  to date, is saved with the site's errors (`Keyfleet.Notebooks.RecordsDownError`).
  """
  use KeyfleetWeb, :controller

  alias Keyfleet.Actors.Human
  alias Keyfleet.{Fleets, Notebooks}
  alias Keyfleet.Keys.Errors.OwnershipRefreshingError
  alias Keyfleet.Notebooks.RecordsDownError
  alias KeyfleetWeb.ContentSecurityPolicy

  def open(conn, %{"fleet_id" => fleet_id} = params) do
    case open_for(conn, fleet_id, params["to"]) do
      {:ok, entry} ->
        nonce = 18 |> :crypto.strong_rand_bytes() |> Base.encode64()
        notebooks = URI.to_string(%{URI.parse(entry.action) | path: nil})

        # The site's referrer policy stays: under `no-referrer` a browser sends
        # the form with the origin `null`, which the notebook host refuses.
        conn
        |> put_resp_header("cache-control", "no-store")
        |> put_resp_header(
          "content-security-policy",
          ContentSecurityPolicy.notebook_entry(nonce, notebooks)
        )
        |> put_root_layout(false)
        |> put_view(html: KeyfleetWeb.NotebookOpenHTML)
        |> render(:entry, entry: entry, nonce: nonce)

      {:error, :no_hub} ->
        conn |> put_flash(:error, "This fleet has no notebooks yet.") |> redirect(to: "/")

      {:error, reason} when is_atom(reason) or is_struct(reason, OwnershipRefreshingError) ->
        to_workspace(conn, fleet_id, reason)

      {:error, error} ->
        RecordsDownError.report(
          "Key ownership in #{fleet_id} could not be read to open its notebooks: " <>
            inspect(error.__struct__)
        )

        to_workspace(conn, fleet_id, error)
    end
  end

  defp to_workspace(conn, fleet_id, reason) do
    conn
    |> put_flash(:error, notice(reason))
    |> redirect(to: Fleets.path(fleet_id) <> "/workspace")
  end

  defp open_for(%Plug.Conn{assigns: %{current_human_account: nil}}, fleet_id, _to),
    do: if(Notebooks.hub?(fleet_id), do: {:error, :signed_out}, else: {:error, :no_hub})

  defp open_for(conn, fleet_id, to) do
    Notebooks.open(
      Human.for_account(conn.assigns.current_human_account),
      conn.assigns.current_lineage,
      fleet_id,
      to
    )
  end

  defp notice(:signed_out), do: "Sign in to open this fleet’s notebooks."
  defp notice(:not_holder), do: "Only holders of this fleet’s Keys can open its notebooks."
  defp notice(:invalid_destination), do: "That notebook link isn’t complete. Ask for it again."
  defp notice(_error), do: "The notebooks can’t be opened right now. Try again in a minute."
end
