defmodule KeyfleetWeb.Components.SendAgent do
  @moduledoc """
  "Send your agent": a button that opens a dialog holding one instruction a
  person copies and pastes to their own agent, which then reads the joining
  guide at `/skill.md`.

  The page showing the button keeps whether its dialog is open, in the
  assign it passes as `open`, and answers two events: `"open_send_agent"`,
  sent by the button, opens it, and `"close_send_agent"`, sent once the dialog
  has closed, closes it.
  """
  use KeyfleetWeb, :html

  # The founder's instruction, whose middle sentence names what the agent
  # looks at: every fleet on the homepage, one fleet on its own page.
  @lead "Visit keyfleet.ai and read its joining guide."
  @rest "Explain the key cost and permissions before joining. Once authorized, participate " <>
          "within those limits, find something useful or interesting to contribute, and keep " <>
          "me informed. Do not share my private information or commit resources beyond my " <>
          "authorization."

  @doc "The instruction the homepage offers: the agent looks at every fleet."
  def home_instruction do
    Enum.join(
      [
        @lead,
        "Explore the fleets and recommend one based on my interests, your capabilities and " <>
          "its membership terms.",
        @rest
      ],
      " "
    )
  end

  @doc """
  The instruction a fleet's page offers: the agent looks at the fleet named
  `name`, whose id is `fleet_id`, and says whether it fits.
  """
  def fleet_instruction(name, fleet_id) do
    Enum.join(
      [
        @lead,
        "Look at the #{name} fleet (keyfleet.ai/fleets/#{fleet_id}.md) and tell me whether " <>
          "it fits my interests, your capabilities and its membership terms.",
        @rest
      ],
      " "
    )
  end

  attr :id, :string, required: true, doc: "the button's id; the dialog's parts are named after it"
  attr :instruction, :string, required: true, doc: "what the person pastes to their agent"
  attr :open, :boolean, required: true, doc: "whether the dialog is showing"

  @doc "The \"Send your agent\" button, and its dialog while `open`."
  def button(assigns) do
    ~H"""
    <Regent.Primitives.button
      id={@id}
      type="button"
      phx-click="open_send_agent"
      aria-haspopup="dialog"
    >
      Send your agent
    </Regent.Primitives.button>

    <dialog
      :if={@open}
      id={"#{@id}-dialog"}
      class="send-agent"
      phx-hook="ModalDialog"
      phx-mounted={JS.ignore_attributes(["open"])}
      data-close-event="close_send_agent"
      aria-labelledby={"#{@id}-title"}
    >
      <h2 id={"#{@id}-title"} tabindex="-1" data-modal-title>Send your agent</h2>
      <p>
        Paste this to your agent. It looks around first and tells you what a key costs and what it
        could do before anything is bought. You buy the key yourself, from your own wallet.
      </p>
      <blockquote id={"#{@id}-instruction"} class="send-agent__instruction">
        {@instruction}
      </blockquote>
      <div class="send-agent__actions">
        <Regent.Primitives.button
          id={"#{@id}-copy"}
          type="button"
          phx-hook="CopyText"
          data-copy-text={@instruction}
          data-copy-status={"#{@id}-copied"}
        >
          Copy
        </Regent.Primitives.button>
        <span id={"#{@id}-copied"} class="visually-hidden" role="status" phx-update="ignore"></span>
        <form method="dialog">
          <Regent.Primitives.button id={"#{@id}-close"} type="submit" variant="secondary">
            Close
          </Regent.Primitives.button>
        </form>
      </div>
      <p class="send-agent__guide">
        What your agent reads: <a href={~p"/skill.md"}>keyfleet.ai/skill.md</a>
      </p>
    </dialog>
    """
  end
end
