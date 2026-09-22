defmodule KeyFleetWeb.ShellLive do
  @moduledoc """
  One LiveView holds the header, sidebar and account control across every in-app
  route and patches between them, so the frame never remounts on navigation.
  """

  use KeyFleetWeb, :live_view

  import KeyFleetWeb.Components.Shell

  alias KeyFleet.Accounts
  alias KeyFleet.Accounts.LinkedIdentity.Providers
  alias KeyFleet.Actors.Human
  alias KeyFleet.Keys
  alias KeyFleetWeb.{AccountLive, KeysLive, OverviewLive, RouteCatalog}

  @identity_providers %{"x" => :x, "github" => :github, "farcaster" => :farcaster}
  @refused "That didn’t go through."

  @impl true
  def mount(params, session, socket) do
    {:ok,
     assign(socket,
       theme: session["theme"],
       route_spec: RouteCatalog.fetch!(socket.assigns.live_action, params),
       shell_instance: System.unique_integer([:positive, :monotonic]),
       verified_connections: [],
       verified_connections_notice: nil,
       key: nil,
       key_notice: nil
     )}
  end

  @impl true
  def handle_params(params, _uri, socket) do
    route_spec = RouteCatalog.fetch!(socket.assigns.live_action, params)

    {:noreply,
     socket
     |> assign(:route_spec, route_spec)
     |> load_verified_connections(route_spec)
     |> load_key(route_spec, params)}
  end

  @impl true
  def handle_event(
        "request_verified_connection",
        %{"action" => action, "provider" => provider},
        socket
      ) do
    with %Human{} <- human_actor(socket),
         {:ok, provider} <- linked_identity_provider(provider),
         {:ok, request} <- identity_request(action, provider, socket.assigns.verified_connections) do
      {:noreply,
       socket
       |> assign(
         verified_connections_notice: %{tone: :info, message: connection_started(request)}
       )
       |> push_event("verified-connections:request", request)}
    else
      _error ->
        {:noreply,
         assign(socket,
           verified_connections_notice: %{
             tone: :error,
             message: "That connection couldn’t be updated. Refresh the page and try again."
           }
         )}
    end
  end

  def handle_event("approve_pairing", %{"id" => id}, socket),
    do: {:noreply, decide(socket, id, &Keys.approve_pairing/3, "That agent now runs this key.")}

  def handle_event("decline_pairing", %{"id" => id}, socket),
    do: {:noreply, decide(socket, id, &Keys.decline_pairing/3, "Request turned down.")}

  def handle_event("detach_operator", %{"id" => id}, socket),
    do: {:noreply, decide(socket, id, &Keys.detach_operator/3, "Operator detached.")}

  def handle_event("refresh_verified_connections", params, socket) do
    socket = reload_verified_connections(socket)

    notice =
      with {:ok, provider} <- linked_identity_provider(params["provider"]),
           {:ok, action} <- identity_action(params["action"]) do
        connection_outcome(params["error"], action, provider, socket.assigns.verified_connections)
      else
        _unknown_outcome -> connection_outcome(params["error"])
      end

    {:noreply, assign(socket, verified_connections_notice: notice)}
  end

  @impl true
  def render(assigns) do
    ~H"""
    <.shell
      route_spec={@route_spec}
      account_control={@account_control}
      shell_instance={@shell_instance}
      theme={@theme}
    >
      <:content>
        <OverviewLive.page
          :if={@route_spec.route_id == :app}
          account_control={@account_control}
          account={current_account(@access_context)}
        />

        <AccountLive.page
          :if={@route_spec.route_id == :account}
          account={current_account(@access_context)}
          account_control={@account_control}
          verified_connections={@verified_connections}
          verified_connections_notice={@verified_connections_notice}
        />

        <KeysLive.page :if={@route_spec.route_id == :keys} key={@key} notice={@key_notice} />
      </:content>
    </.shell>
    """
  end

  defp current_account(%{principal: {:human, account}}), do: account
  defp current_account(_access_context), do: nil

  defp load_key(socket, %{route_id: :keys}, %{"fleet_id" => fleet_id, "token_id" => token_id}) do
    assign(socket,
      key: key_view(socket, fleet_id, String.to_integer(token_id)),
      key_notice: nil
    )
  end

  defp load_key(socket, _route_spec, _params), do: assign(socket, key: nil, key_notice: nil)

  defp key_view(socket, fleet_id, token_id) do
    actor = human_actor(socket)
    key = Keys.current_key!(fleet_id, token_id, actor: actor, load: [:fleet])

    %{
      fleet_id: fleet_id,
      token_id: token_id,
      fleet_name: key && key.fleet.name,
      owner_wallet: key && key.owner_wallet,
      current_epoch: key && key.ownership_epoch,
      owner?: owns_key?(actor, key),
      operator: Keys.current_operator!(fleet_id, token_id, actor: actor),
      requests: Keys.list_pairing_requests!(fleet_id, token_id, actor: actor),
      history: Keys.pairing_history!(fleet_id, token_id, actor: actor)
    }
  end

  defp owns_key?(%Human{wallet_addresses: wallets}, %{owner_wallet: owner}),
    do: owner in wallets

  defp owns_key?(_actor, _key), do: false

  # The buttons act on what the page is showing; the key itself decides whether
  # the decision still applies, and the page is redrawn from the answer either
  # way, so a page left open on a key that has moved on catches up.
  defp decide(socket, id, decision, message) do
    with %Human{} = actor <- human_actor(socket),
         %{} = pairing <- Enum.find(shown_pairings(socket), &(&1.id == id)),
         {:ok, _decided} <- decision.(pairing, %{}, actor: actor) do
      redraw_key(socket, %{tone: :success, message: message})
    else
      refusal -> redraw_key(socket, %{tone: :error, message: refusal_message(refusal)})
    end
  end

  defp refusal_message({:error, %Ash.Error.Invalid{errors: errors}}) do
    if Enum.any?(errors, &match?(%Ash.Error.Changes.StaleRecord{}, &1)),
      do: "This request was already answered.",
      else: @refused
  end

  defp refusal_message(_refusal), do: @refused

  defp redraw_key(%{assigns: %{key: %{fleet_id: fleet_id, token_id: token_id}}} = socket, notice) do
    socket
    |> assign(:key, key_view(socket, fleet_id, token_id))
    |> assign(:key_notice, notice)
  end

  defp redraw_key(socket, notice), do: assign(socket, :key_notice, notice)

  defp shown_pairings(%{assigns: %{key: %{operator: operator, requests: requests}}}),
    do: [operator | requests] |> Enum.reject(&is_nil/1)

  defp shown_pairings(_socket), do: []

  defp load_verified_connections(socket, %{route_id: :account}),
    do: reload_verified_connections(socket)

  defp load_verified_connections(socket, _route_spec),
    do: assign(socket, verified_connections: [], verified_connections_notice: nil)

  # The account's own record is the only thing a connection is read from, so
  # nothing the browser reports can name a connection the record does not hold.
  defp reload_verified_connections(socket) do
    case human_actor(socket) do
      %Human{} = actor ->
        case Accounts.list_my_linked_identities(actor: actor) do
          {:ok, identities} -> assign(socket, verified_connections: identities)
          {:error, _error} -> assign(socket, verified_connections: [])
        end

      nil ->
        assign(socket, verified_connections: [])
    end
  end

  defp linked_identity_provider(provider) do
    case Map.fetch(@identity_providers, provider) do
      {:ok, provider} -> {:ok, provider}
      :error -> {:error, :invalid_provider}
    end
  end

  defp identity_request("link", provider, _identities) do
    {:ok, %{action: :link, provider: provider}}
  end

  defp identity_request("unlink", provider, identities) do
    case Enum.find(identities, &(&1.provider == provider)) do
      nil -> {:error, :not_connected}
      identity -> {:ok, %{action: :unlink, provider: provider, subject: identity.subject}}
    end
  end

  defp identity_request(_action, _provider, _identities), do: {:error, :invalid_action}

  defp identity_action("link"), do: {:ok, :link}
  defp identity_action("unlink"), do: {:ok, :unlink}
  defp identity_action(_action), do: {:error, :invalid_action}

  # X and GitHub take the whole tab to their own approval page and bring it
  # back; Farcaster asks for a scan here.
  defp connection_started(%{action: :link, provider: :farcaster}),
    do: "Scan the code with Farcaster to approve the connection."

  defp connection_started(%{action: :link, provider: provider}),
    do: "Taking you to #{Providers.label(provider)} to approve the connection."

  defp connection_started(%{action: :unlink, provider: provider}),
    do: "Disconnecting #{Providers.label(provider)}…"

  defp connection_outcome("already-connected"),
    do: %{tone: :error, message: "That account is already connected to another account here."}

  defp connection_outcome(error) when is_binary(error) and error != "",
    do: %{tone: :error, message: "That connection couldn’t be verified. Try again."}

  defp connection_outcome(_none), do: nil

  defp connection_outcome(error, _action, _provider, _identities)
       when is_binary(error) and error != "",
       do: connection_outcome(error)

  defp connection_outcome(_none, action, provider, identities) do
    label = Providers.label(provider)

    case {action, Enum.any?(identities, &(&1.provider == provider))} do
      {:link, true} ->
        %{tone: :success, message: "#{label} connected."}

      {:link, false} ->
        %{tone: :error, message: "#{label} didn’t come back connected. Try again."}

      {:unlink, false} ->
        %{tone: :success, message: "#{label} disconnected."}

      {:unlink, true} ->
        %{tone: :error, message: "#{label} is still connected. Try again."}
    end
  end

  defp human_actor(%{assigns: %{access_context: %{principal: {:human, account}}}}),
    do: %Human{human_account_id: account.id, wallet_addresses: account_wallets(account)}

  defp human_actor(_socket), do: nil

  defp account_wallets(account) do
    [account.wallet_address | List.wrap(account.wallet_addresses)]
    |> Enum.filter(&is_binary/1)
    |> Enum.map(&String.downcase/1)
    |> Enum.uniq()
  end
end
