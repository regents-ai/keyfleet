defmodule KeyfleetWeb.AdminMessagesLive do
  @moduledoc """
  The messages agents and people left for the site's team
  (`Keyfleet.LeftMessages`), newest first, 50 a page, for the site's admins
  only: the route sits behind the same check as the saved errors
  (`KeyfleetWeb.ErrorsAdmin`), which hands the page its admin actor, and the
  read's own policy asks again (`RegentAgents.Checks.Admin`). `?after=` holds
  the cursor of the page before. An agent's message shows the name it left it
  under and is marked as an agent's.
  """

  use KeyfleetWeb, :live_view

  alias Keyfleet.LeftMessages
  alias KeyfleetWeb.Read
  alias Regent.Primitives

  @impl true
  def mount(_params, _session, socket) do
    {:ok,
     assign(socket,
       page_title: "Messages",
       page_description: "Messages agents and people left for the site's team.",
       messages: %Read{}
     )}
  end

  @impl true
  def handle_params(params, _uri, socket) do
    cursor = params["after"]
    page = if cursor, do: [after: cursor], else: []

    {:noreply,
     Read.now(socket, :messages, cursor, fn ->
       LeftMessages.list_left_messages(actor: socket.assigns.admin, page: page)
     end)}
  end

  @impl true
  def render(assigns) do
    ~H"""
    <div class="rl-root legal-root rg-sheet rg-frame admin-messages">
      <main class="legal-page">
        <h1>Messages</h1>
        <Primitives.notice :if={@messages.state in [:error, :stale]} tone="error">
          The messages couldn’t be read. Refresh the page to try again.
        </Primitives.notice>
        <Primitives.empty_state
          :if={match?(%{state: :ready, value: %{results: []}}, @messages)}
          title="No messages"
        >
          Messages agents and people leave for the team show here.
        </Primitives.empty_state>
        <ol :if={@messages.state == :ready} id="admin-messages" class="admin-messages__list">
          <li :for={message <- @messages.value.results} id={"message-#{message.id}"}>
            <dl class="admin-messages__meta">
              <div>
                <dt>Topic</dt>
                <dd><code>{message.topic}</code></dd>
              </div>
              <div>
                <dt>From</dt>
                <dd>
                  <bdi>{message.sender_name}</bdi>
                  <span :if={message.agent_profile_id}>· Agent</span>
                </dd>
              </div>
              <div>
                <dt>Sent</dt>
                <dd>
                  <time datetime={DateTime.to_iso8601(message.inserted_at)}>
                    {Calendar.strftime(message.inserted_at, "%-d %b %Y, %H:%M UTC")}
                  </time>
                </dd>
              </div>
              <div :if={message.reply_to}>
                <dt>Reply to</dt>
                <dd><bdi>{message.reply_to}</bdi></dd>
              </div>
            </dl>
            <p class="admin-messages__body">{message.body}</p>
          </li>
        </ol>
        <.link
          :if={@messages.state == :ready and @messages.value.more?}
          patch={"?after=" <> List.last(@messages.value.results).__metadata__.keyset}
          class="rg-button rg-button--secondary"
        >
          Older
        </.link>
      </main>
    </div>
    """
  end
end
