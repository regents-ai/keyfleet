defmodule KeyfleetWeb.AgentMessageLive do
  @moduledoc """
  The Agent Message form's own live view on a plain page: the window
  (`KeyfleetWeb.Components.AgentMessage.dialog/1` with `conn`) draws it with
  `live_render(@conn, …)`, so it reads the sign-in itself
  (`KeyfleetWeb.Live.Session`) and keeps the client key of the request that
  drew it. It holds only the form (`KeyfleetWeb.Components.AgentMessage.Form`),
  which a live page places directly.
  """

  use KeyfleetWeb, :live_view

  alias Keyfleet.AccessContext
  alias KeyfleetWeb.Components.AgentMessage.Form

  on_mount {KeyfleetWeb.Live.Session, :load_human}

  @impl true
  def mount(_params, %{"id" => id, "topic" => topic, "client_key" => client_key}, socket),
    do: {:ok, assign(socket, id: id, topic: topic, client_key: client_key), layout: false}

  @impl true
  def render(assigns) do
    ~H"""
    <.live_component
      module={Form}
      id={@id}
      topic={@topic}
      account={account(@access_context)}
      lease={@session_lease}
      client_key={@client_key}
    />
    """
  end

  defp account(%AccessContext{principal: {:human, account}}), do: account
  defp account(_signed_out), do: nil
end
