defmodule KeyfleetWeb.Components.IdleKeys do
  @moduledoc """
  How many of a fleet's Keys are idle, and the list of them. An idle Key has
  no vote until it is marked present again: its 48 hours ran out, or it
  changed hands.

  The field shows the count. Pressing it opens a dialog listing the idle Keys
  by number, a hundred at a time, each linking to its Key's profile. The count
  is read from the site's record of the fleet's presence when the page loads
  and again each time the list opens.
  """
  use KeyfleetWeb, :live_component

  alias Keyfleet.Fleets.Rules
  alias Keyfleet.Keys
  alias KeyfleetWeb.KeyLinks

  @impl true
  def mount(socket),
    do:
      {:ok,
       socket
       |> assign(open?: false, next: nil, unlisted?: false, listed?: false)
       |> stream(:keys, [])}

  @impl true
  def update(assigns, socket) do
    socket = assign(socket, assigns)

    {:ok,
     if(changed?(socket, :fleet_id),
       do: socket |> assign(open?: false) |> count(),
       else: socket
     )}
  end

  @impl true
  def handle_event("open", _params, socket),
    do: {:noreply, socket |> count() |> assign(open?: true) |> page([], reset: true)}

  def handle_event("more", _params, %{assigns: %{next: keyset}} = socket)
      when is_binary(keyset),
      do: {:noreply, page(socket, [after: keyset], [])}

  # A second press of More that lands after the last hundred arrived.
  def handle_event("more", _params, socket), do: {:noreply, socket}

  def handle_event("close", _params, socket), do: {:noreply, assign(socket, open?: false)}

  # How many Keys are idle, or nil when they couldn't be counted; the field
  # says so rather than showing a number.
  defp count(%{assigns: %{fleet_id: fleet_id}} = socket) do
    case Keys.count_idle_keys(fleet_id) do
      {:ok, count} -> assign(socket, count: count)
      {:error, _failure} -> assign(socket, count: nil)
    end
  end

  # The next hundred idle Keys, and where the hundred after them begin. When
  # they couldn't be read the list stays as it was and says so; pressing
  # again tries again. The stream keeps no rows here, so whether it holds any
  # is remembered beside it.
  defp page(%{assigns: %{fleet_id: fleet_id}} = socket, position, stream_opts) do
    case Keys.idle_keys_page(fleet_id, position) do
      {:ok, %Ash.Page.Keyset{results: keys, more?: more?}} ->
        socket
        |> stream(:keys, keys, stream_opts)
        |> assign(
          unlisted?: false,
          listed?: keys != [] or (socket.assigns.listed? and stream_opts[:reset] != true),
          next: if(more?, do: List.last(keys).__metadata__.keyset)
        )

      {:error, _failure} ->
        assign(socket, unlisted?: true)
    end
  end

  @impl true
  def render(assigns) do
    ~H"""
    <div id={@id} class="idle-keys">
      <button
        id={"#{@id}-open"}
        type="button"
        class="idle-keys__field"
        phx-click="open"
        phx-target={@myself}
        aria-haspopup="dialog"
      >
        <span>Idle</span>
        <strong id={"#{@id}-count"}>{figure(@count)}</strong>
      </button>

      <dialog
        :if={@open?}
        id={"#{@id}-dialog"}
        class="idle-keys__dialog"
        phx-hook="ModalDialog"
        phx-mounted={JS.ignore_attributes(["open", "style"])}
        data-close-event="close"
        aria-labelledby={"#{@id}-title"}
      >
        <h2 id={"#{@id}-title"} tabindex="-1" data-modal-title>Idle Keys</h2>
        <%!-- Said from the list itself, so a count that failed never leaves it blank. --%>
        <p :if={not @listed? and not @unlisted?} id={"#{@id}-none"}>
          No Keys are idle.
        </p>
        <p :if={@unlisted?} id={"#{@id}-unlisted"} role="status">
          The list couldn’t be read. Close it and try again.
        </p>
        <ol id={"#{@id}-list"} class="idle-keys__list" phx-update="stream" data-modal-scroll>
          <li :for={{dom_id, key} <- @streams.keys} id={dom_id}>
            <.link
              id={"#{@id}-key-#{key.token_id}"}
              patch={KeyLinks.key_path(@fleet_id, key.token_id)}
            >
              Key {Rules.grouped(key.token_id)}
            </.link>
            <span>Held by {RegentFormat.short_address(key.owner_wallet)}</span>
          </li>
        </ol>
        <div class="idle-keys__actions">
          <Regent.Primitives.button
            :if={@next}
            id={"#{@id}-more"}
            type="button"
            variant="secondary"
            phx-click="more"
            phx-target={@myself}
          >
            Show more
          </Regent.Primitives.button>
          <form method="dialog">
            <Regent.Primitives.button id={"#{@id}-close"} type="submit" variant="secondary">
              Close
            </Regent.Primitives.button>
          </form>
        </div>
      </dialog>
    </div>
    """
  end

  defp figure(nil), do: "—"
  defp figure(count), do: Rules.grouped(count)
end
