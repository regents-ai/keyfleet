defmodule KeyfleetWeb.Live.LaunchGateHook do
  @moduledoc """
  Keeps the homepage and the product LiveViews closed while the site is closed,
  sending them to `/early` as `KeyfleetWeb.Plugs.LaunchGate` sends a fresh
  request. It covers mounts that reach the socket without a fresh request:
  reconnects and live navigation from a page loaded before the site closed.

  The mount check alone would let a page opened while the gate was open keep
  moving between the routes it covers, since those moves patch the running
  LiveView instead of asking for a new page, so every navigation is checked too.

  The reading pages the plug leaves open stay open here too, by their live
  action.
  """

  use KeyfleetWeb, :verified_routes

  import Phoenix.LiveView, only: [attach_hook: 4, redirect: 2]

  alias KeyfleetWeb.Plugs.LaunchGate

  @reading [:agents, :agent, :docs, :changelog, :about, :privacy, :terms]

  def on_mount(:default, _params, _session, socket) do
    with {:cont, socket} <- app_gate(socket) do
      {:cont, attach_hook(socket, :launch_gate, :handle_params, &gate_navigation/3)}
    end
  end

  defp gate_navigation(_params, _uri, socket), do: app_gate(socket)

  defp app_gate(socket) do
    if socket.assigns.live_action in @reading or LaunchGate.app_surfaces_enabled?(),
      do: {:cont, socket},
      else: {:halt, redirect(socket, to: ~p"/early")}
  end
end
