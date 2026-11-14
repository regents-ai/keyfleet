defmodule KeyfleetWeb.Plugs.ProfileOwner do
  @moduledoc """
  Puts the profile's owner on a profile API request (`RegentIdentity.HTTP`).

  An agent's signed request was admitted before the parsers
  (`KeyfleetWeb.Plugs.SignedAgent`) and acts as the person it is paired with,
  or is refused with `person_not_here` while that person has no account here.
  Any other request is the person's session cookie, whose change carries the
  session's forms token in x-csrf-token, as the site's pages send it; one
  without it counts as signed out, so another site's page can never act with
  the person's cookie. A signed-out request gets no owner, and the profile API
  refuses it with `authentication_required`.
  """

  @behaviour Plug

  import Plug.Conn

  alias Keyfleet.Actors.{Agent, Human}
  alias KeyfleetWeb.{PrivySessionController, Refusal}

  @forms_token Plug.CSRFProtection.init(with: :clear_session)

  @impl true
  def init(opts), do: opts

  @impl true
  def call(%{assigns: %{agent_actor: %Agent{pairing: %Human{}} = agent}} = conn, _opts),
    do: owner(conn, agent.privy_user_id)

  def call(%{assigns: %{agent_actor: %Agent{}}} = conn, _opts) do
    conn
    |> put_resp_header("cache-control", "no-store")
    |> Refusal.json(403, "person_not_here")
    |> halt()
  end

  def call(conn, _opts) do
    conn =
      conn
      |> fetch_session()
      |> Plug.CSRFProtection.call(@forms_token)
      |> PrivySessionController.enforce_authority()

    case conn.assigns.current_human_account do
      %{privy_user_id: privy_user_id} -> owner(conn, privy_user_id)
      nil -> conn
    end
  end

  defp owner(conn, privy_user_id) do
    app_id = :keyfleet |> Application.fetch_env!(:privy) |> Keyword.fetch!(:app_id)

    RegentIdentity.HTTP.put_owner(conn, %RegentIdentity.Owner{
      app_id: app_id,
      privy_user_id: privy_user_id
    })
  end
end
