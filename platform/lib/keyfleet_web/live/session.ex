defmodule KeyfleetWeb.Live.Session do
  @moduledoc false

  import Phoenix.Component, only: [assign: 2]
  import Phoenix.LiveView, only: [attach_hook: 4, connected?: 1, get_connect_info: 2, redirect: 2]

  alias Keyfleet.AccessContext
  alias Keyfleet.Accounts.SessionAuthority

  @public_root "/"

  @doc """
  What the render knew, signed into the static LiveView token. The token is
  integrity-only and readable by anyone holding the markup, so it carries the
  lineage-stable topic, a digest that names the browser session without being
  able to authenticate as it, rather than the lineage. The route travels with it
  because a connected mount cannot otherwise learn it before `handle_params`,
  which is too late to refuse the mount. LiveView merges these keys over the
  handshake session, so they can never stand in for the authority the socket
  connected with.
  """
  def render_context(conn) do
    conn.assigns.current_lineage
    |> rendered_topic()
    |> Map.put("render_route", local_route(conn.request_path, conn.query_string))
  end

  # Pages outside the product shell only show who is signed in, in the site
  # header; they act for nobody, so they hold no lease.
  def on_mount(:show_account, _params, session, socket) do
    {_lineage, account} = session |> SessionAuthority.claim() |> SessionAuthority.resolve()
    {:cont, socket |> assign(signed_out_reason: :signed_out) |> assign_principal(account)}
  end

  def on_mount(:load_human, _params, session, socket) do
    socket = assign(socket, session_lease: nil, signed_out_reason: :signed_out)

    if connected?(socket) do
      connected(socket, session, get_connect_info(socket, :session))
    else
      {_lineage, account} = session |> SessionAuthority.claim() |> SessionAuthority.resolve()
      {:cont, assign_principal(socket, account)}
    end
  end

  # The cookie the socket connected with is the only authority, and a mount that
  # cannot honour it is refused here, not left to a later hook. An exactly
  # current claim drives the socket when the page was rendered for its lineage;
  # otherwise one full request for the same route realigns them. Anything else
  # lands on the public root, which is outside the product shell and so cannot
  # raise the same rejection again.
  defp connected(socket, %{"render_topic" => rendered} = static, handshake),
    do: admit(socket, rendered, static["render_route"], SessionAuthority.claim(handshake))

  defp connected(socket, static, handshake) do
    if SessionAuthority.claim_shaped?(handshake),
      do: admit(socket, nil, static["render_route"], SessionAuthority.claim(handshake)),
      else: {:cont, assign_principal(socket, nil)}
  end

  defp admit(socket, _rendered, _route, nil), do: {:halt, redirect(socket, to: @public_root)}

  defp admit(socket, rendered, route, %{lineage: lineage} = claim) do
    with {^lineage, account} <- SessionAuthority.resolve(claim),
         ^rendered <- SessionAuthority.topic(lineage) do
      {:cont, hold(socket, lineage, account)}
    else
      {nil, nil} -> {:halt, redirect(socket, to: @public_root)}
      _other_session -> {:halt, redirect(socket, to: route)}
    end
  end

  defp hold(socket, _lineage, nil), do: assign_principal(socket, nil)

  # The lease holds no generation, because a same-account refresh advances it
  # beneath a live socket. Lineage, account binding, revocation and the
  # account's own provider evidence are re-read every time, and the principal is
  # rebuilt from that read rather than from the struct the mount captured. A
  # lapsed lease withdraws the principal, so nothing downstream can still
  # present it as authority, and a page that stays open says the sign-in ended
  # (`signed_out_reason: :expired`) rather than that no one signed in. Components receive the lease as `session_lease`
  # and check it on their own events (`check_component_events/1`); one that
  # finds it lapsed asks the page to withdraw the principal here.
  defp hold(socket, lineage, account) do
    lease = %{lineage: lineage, account_id: account.id}

    socket
    |> assign_principal(account)
    # Opening a fleet's notebooks names the sign-in they hang on.
    |> assign(session_lineage: lineage, session_lease: lease)
    |> attach_hook(:session_authority_params, :handle_params, fn _params, _uri, socket ->
      recheck(socket, lease, &redirect(&1, to: @public_root))
    end)
    |> attach_hook(:session_authority_event, :handle_event, fn _event, _params, socket ->
      recheck(socket, lease, & &1)
    end)
    |> attach_hook(:session_authority_info, :handle_info, fn
      {__MODULE__, :component_lease_lapsed}, socket ->
        {_cont_or_halt, socket} = recheck(socket, lease, & &1)
        {:halt, socket}

      # Direct messages are private, so the page reads a new or deleted one
      # only as the sign-in read again now: a wallet unlinked since reads no
      # more of its Key's messages, and a sign-in that has ended leaves the
      # page, as it does on the next address.
      %Phoenix.Socket.Broadcast{event: event}, socket
      when event in ["dm_head", "dm_deleted"] ->
        recheck(socket, lease, &redirect(&1, to: @public_root))

      # A change to the person's Credits or agents is read again only for a
      # sign-in that still holds; one that has ended renders signed out.
      message, socket when message in [:credits_changed, :agents_changed] ->
        recheck(socket, lease, & &1)

      _message, socket ->
        {:cont, socket}
    end)
  end

  @doc """
  A LiveComponent's events never reach the page's own event hook, so every
  component that acts calls this from `mount/1`, and its page passes it the
  page's `session_lease` as `lease`. Each event first re-reads that lease, as
  the page does for its own events. A lapsed lease refuses the event with an
  empty reply, so a wallet step it was asked for is not sent, and tells the
  page, which withdraws the principal and renders signed out. A page with no
  signed-in session passes a nil lease and its components act as before.
  """
  def check_component_events(socket) do
    attach_hook(socket, :session_authority_event, :handle_event, fn
      _event, _params, %{assigns: %{lease: nil}} = socket ->
        {:cont, socket}

      _event, _params, %{assigns: %{lease: lease}} = socket ->
        if SessionAuthority.leased_account(lease.lineage, lease.account_id) do
          {:cont, socket}
        else
          send(self(), {__MODULE__, :component_lease_lapsed})
          {:halt, %{}, socket}
        end
    end)
  end

  defp recheck(socket, lease, lapsed) do
    case SessionAuthority.leased_account(lease.lineage, lease.account_id) do
      nil ->
        {:halt,
         socket |> assign_principal(nil) |> assign(signed_out_reason: :expired) |> lapsed.()}

      account ->
        {:cont, assign_principal(socket, account)}
    end
  end

  defp rendered_topic(nil), do: %{}
  defp rendered_topic(lineage), do: %{"render_topic" => SessionAuthority.topic(lineage)}

  defp local_route(path, ""), do: path
  defp local_route(path, query), do: path <> "?" <> query

  defp assign_principal(socket, account) do
    context = AccessContext.for_account(account)

    assign(socket,
      access_context: context,
      account_control: AccessContext.account_control(context)
    )
  end
end
