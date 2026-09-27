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

  alias KeyfleetWeb.Motion

  # The joining guide says everything else the agent should do.
  @lead "Visit keyfleet.ai and read its joining guide."

  @doc "The instruction the homepage offers, which also begins a fleet page's."
  def home_instruction, do: @lead

  @doc "The instruction a fleet's page offers: the guide, then the fleet named `name`."
  def fleet_instruction(name), do: "#{@lead} Then look at the #{name} fleet."

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
      phx-mounted={JS.ignore_attributes(["open", "style"])}
      data-variant={Motion.standard("sheet")}
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
        <Regent.Primitives.copy_button id={"#{@id}-copy"} variant="primary" text={@instruction}>
          Copy
        </Regent.Primitives.copy_button>
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
