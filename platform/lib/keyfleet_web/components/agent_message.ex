defmodule KeyfleetWeb.Components.AgentMessage do
  @moduledoc """
  The Agent Message button and its window: three texts a visitor pastes into
  their agent so it leaves a private message for Keyfleet's team under a
  `topic` the site names, through the regents CLI, the hosted MCP server or the
  site's WebMCP tool. Each names this site's address and the command and tool
  read when this module compiles from `cli/commands.json` and
  `priv/tool_manifest.json`, the files every surface is checked against, so the
  texts cannot name a command that is not there. `texts/1` gives them to any
  page that tells an agent how.

  Below the texts, a signed-in person leaves a message themselves
  (`KeyfleetWeb.Components.AgentMessage.Form`), on a plain page and on a live
  page alike; a signed-out visitor sees only the texts.
  """

  use Phoenix.Component

  alias KeyfleetWeb.Live.Session
  alias KeyfleetWeb.PublicDocuments

  commands = Path.expand("../../../../cli/commands.json", __DIR__)
  manifest = Application.app_dir(:keyfleet, "priv/tool_manifest.json")
  @external_resource commands
  @external_resource manifest

  %{"platform" => platform, "commands" => commands} = commands |> File.read!() |> Jason.decode!()

  %{"command" => command, "webmcp" => tool} =
    Enum.find(commands, &(&1["operation_id"] == "leaveMessage"))

  %{"name" => ^tool} =
    manifest
    |> File.read!()
    |> Jason.decode!()
    |> Map.fetch!("tools")
    |> Enum.find(&(&1["route"] == "POST /api/v1/messages/{topic}"))

  # `messages leave <topic>`, with the topic left for `texts/1` to fill in.
  @command "regents #{platform} " <> String.replace(command, "<topic>", "")
  @tool tool

  @doc """
  The three paste-ready texts for leaving a message under `topic`, each with its
  one-word title: the CLI line, the hosted MCP tool call and the WebMCP tool
  call, with this site's address and names filled in.
  """
  @spec texts(String.t()) :: [%{id: String.t(), title: String.t(), text: String.t()}]
  def texts(topic) do
    site = PublicDocuments.url("")

    input = fn first ->
      Jason.encode!(
        Jason.OrderedObject.new(
          first ++
            [
              body: "<your message>",
              reply_to: "<where to answer you>",
              operation_id: "<a new UUID>"
            ]
        ),
        pretty: true
      )
    end

    [
      %{
        id: "cli",
        title: "CLI",
        text: """
        Leave a message for the team at #{site} with the regents CLI, signed as you:

        echo '#{Jason.encode!(Jason.OrderedObject.new(body: "<your message>", reply_to: "<where to answer you>", operation_id: "<a new UUID>"))}' | #{@command}#{topic}

        If your regents CLI doesn't have this command yet, send the signed request #{site}/commands.json names for it. Keep the same operation_id if you retry. Only the team reads it.\
        """
      },
      %{
        id: "mcp",
        title: "MCP",
        text: """
        Leave a message for the team at #{site} with its hosted MCP server, #{site}/mcp. Call its #{@tool} tool with this input, signed by your agent:

        #{input.(topic: topic)}

        Keep the same operation_id if you retry. Only the team reads it.\
        """
      },
      %{
        id: "webmcp",
        title: "WebMCP",
        text: """
        Open #{site} in your browser and call the WebMCP tool #{@tool}, signed with your agent key, with this input:

        #{input.(topic: topic)}

        Keep the same operation_id if you retry. Only the team reads it.\
        """
      }
    ]
  end

  attr :id, :string, required: true
  attr :dialog, :string, required: true, doc: "The id of the `dialog/1` it opens."
  attr :class, :any, default: nil

  @doc "The Agent Message button, which opens its window."
  def button(assigns) do
    ~H"""
    <Regent.Primitives.button
      id={@id}
      variant="secondary"
      arrow={false}
      class={["agent-message-button", @class]}
      aria-haspopup="dialog"
      aria-controls={@dialog}
      data-agent-message-open
    >
      <Regent.Icons.icon name="bot-message-square" /> Agent Message
    </Regent.Primitives.button>
    """
  end

  attr :id, :string, required: true
  attr :topic, :string, required: true, doc: "The topic its messages are left under."

  attr :conn, Plug.Conn,
    default: nil,
    doc: "On a plain page: the page's request, from which the form reads the sign-in."

  attr :account, :map, default: nil, doc: "On a live page: the signed-in account, or nil."
  attr :lease, :map, default: nil, doc: "On a live page: its `session_lease`."
  attr :client_key, :string, default: nil, doc: "On a live page: its client key."

  @doc """
  The window: the three texts, each with its copy button, and for a signed-in
  person the form that leaves a message (`AgentMessage.Form`). Closed with its
  X, Escape or a press beside it (`assets/js/agent_message.ts`).

  A plain page passes its `conn`, and the form runs in a live view of its own
  (`KeyfleetWeb.AgentMessageLive`), which keeps the client key of the request
  that drew it (`KeyfleetWeb.ClientAddress.client_key/1`); a live page passes
  its signed-in `account`, `session_lease` as `lease` and its client key, and
  the form runs in it.
  """
  def dialog(assigns) do
    assigns = assign(assigns, texts: texts(assigns.topic), form: "#{assigns.id}-person")

    ~H"""
    <Regent.Structure.dialog
      id={@id}
      class="agent-message"
      aria-labelledby={"#{@id}-title"}
      data-agent-message
      phx-mounted={Phoenix.LiveView.JS.ignore_attributes(["open"])}
    >
      <header class="agent-message__top">
        <h2 id={"#{@id}-title"}>Agent Message</h2>
        <button
          type="button"
          class="agent-message__close"
          aria-label="Close"
          data-agent-message-close
        >
          <Regent.Icons.icon name="x" />
        </button>
      </header>
      <p class="agent-message__note">
        Paste one of these into your agent. It leaves a private message that only Keyfleet's team reads.
      </p>
      <ol class="agent-message__texts">
        <li :for={text <- @texts} class="agent-message__text">
          <div class="agent-message__head">
            <h3>{text.title}</h3>
            <Regent.Primitives.copy_button
              id={"#{@id}-copy-#{text.id}"}
              variant="quiet"
              target={"#{@id}-text-#{text.id}"}
            >
              Copy
            </Regent.Primitives.copy_button>
          </div>
          <pre><code id={"#{@id}-text-#{text.id}"}>{text.text}</code></pre>
        </li>
      </ol>
      <%= if @conn do %>
        {Phoenix.Component.live_render(@conn, KeyfleetWeb.AgentMessageLive,
          id: "#{@id}-live",
          session:
            @conn
            |> Session.render_context()
            |> Map.merge(%{
              "id" => @form,
              "topic" => @topic,
              "client_key" =>
                @conn |> KeyfleetWeb.ClientAddress.key() |> KeyfleetWeb.ClientAddress.client_key()
            })
        )}
      <% else %>
        <.live_component
          module={KeyfleetWeb.Components.AgentMessage.Form}
          id={@form}
          topic={@topic}
          account={@account}
          lease={@lease}
          client_key={@client_key}
        />
      <% end %>
    </Regent.Structure.dialog>
    """
  end
end
