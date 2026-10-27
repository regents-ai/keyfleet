defmodule KeyfleetWeb.Live.Session do
  @moduledoc false

  import Phoenix.Component, only: [assign: 2]
  import Phoenix.LiveView, only: [attach_hook: 4, connected?: 1, get_connect_info: 2, redirect: 2]

  alias Keyfleet.AccessContext
  alias Keyfleet.Accounts.{EnsIdentity, SessionAuthority}

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
    |> Map.merge(%{
      "render_route" => local_route(conn.request_path, conn.query_string),
      "visit" => conn.assigns.visit
    })
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
  # lands on the public root, whose page names a cookie the server refuses, so
  # the browser retires it before the socket connects and the root cannot raise
  # the same rejection again.
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
  # (`signed_out_reason: :expired`) rather than that no one signed in. A
  # finished ENS lookup reads the account again, so the header shows the name
  # and picture it found.
  #
  # Every message and every background result is re-read the same way before
  # the page sees it, because a notification or a read can arrive after the
  # sign-in has outlived its lifetime with no navigation or event between. A
  # lapsed lease then drops it and the page renders signed out. Components
  # receive the lease as `session_lease` and check it on their own events and
  # results (`check_component_lease/2`); one that finds it lapsed asks the page
  # to withdraw the principal here.
  defp hold(socket, lineage, account) do
    lease = %{lineage: lineage, account_id: account.id}
    ens_topic = EnsIdentity.topic(account.id)
    Phoenix.PubSub.subscribe(Keyfleet.PubSub, ens_topic)

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
      %{topic: ^ens_topic}, socket ->
        {_cont_or_halt, socket} = recheck(socket, lease, & &1)
        {:halt, socket}

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

      _message, socket ->
        recheck(socket, lease, & &1)
    end)
    |> attach_hook(:session_authority_async, :handle_async, fn _name, _result, socket ->
      recheck(socket, lease, & &1)
    end)
  end

  @doc """
  A LiveComponent's events and background results never reach the page's own
  hooks, so every component that acts calls this from `mount/1`, and its page
  passes it the page's `session_lease` as `lease`. Each event and each result
  first re-reads that lease, as the page does for its own. A current lease
  hands `take_account`, the component's own function, the account as it reads
  now, and the component rebuilds from it the wallets and actor it acts with,
  so nothing acts on a wallet list or actor captured earlier. A lapsed lease
  refuses the event with an empty reply, so a wallet step it was asked for is
  not sent, or drops the result unseen, and tells the page, which withdraws the
  principal and renders signed out. A page with no signed-in session passes a
  nil lease and the component acts on what the page gave it.
  """
  def check_component_lease(socket, take_account) do
    socket
    |> attach_hook(:session_authority_event, :handle_event, fn _event, _params, socket ->
      case component_account(socket) do
        :lapsed -> {:halt, %{}, socket}
        account -> {:cont, take(socket, take_account, account)}
      end
    end)
    |> attach_hook(:session_authority_async, :handle_async, fn _name, _result, socket ->
      case component_account(socket) do
        :lapsed -> {:halt, socket}
        account -> {:cont, take(socket, take_account, account)}
      end
    end)
  end

  defp component_account(%{assigns: %{lease: nil}}), do: :signed_out

  defp component_account(%{assigns: %{lease: lease}}) do
    case SessionAuthority.leased_account(lease.lineage, lease.account_id) do
      nil ->
        send(self(), {__MODULE__, :component_lease_lapsed})
        :lapsed

      account ->
        account
    end
  end

  defp take(socket, _take_account, :signed_out), do: socket
  defp take(socket, take_account, account), do: take_account.(socket, account)

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
