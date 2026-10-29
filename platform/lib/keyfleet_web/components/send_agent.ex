defmodule KeyfleetWeb.Components.SendAgent do
  @moduledoc """
  "Send your agent": a button that opens a dialog holding one instruction a
  person copies and pastes to their own agent, which then installs the
  joining guide at `/skill.md` as its Keyfleet skill.

  The page showing the button keeps whether its dialog is open, in the
  assign it passes as `open`, and answers two events: `"open_send_agent"`,
  sent by the button, opens it, and `"close_send_agent"`, sent once the dialog
  has closed, closes it.
  """
  use KeyfleetWeb, :html

  # The joining guide says everything else the agent should do.
  @lead "Install the Keyfleet skill from keyfleet.ai/skill.md and follow it."

  @doc "The instruction the homepage offers, which also begins a fleet page's."
  def home_instruction, do: @lead

  @doc """
  The setup step for the agent on the runtime `slug`, as `{heading, line}`:
  the line to give it is its own skill (`KeyfleetWeb.AgentGuides`). Claude runs
  no commands and installs no skill, so its person adds the Keyfleet connector
  at this site's `/mcp` address instead.
  """
  def runtime_step("claude"),
    do:
      {"Connector",
       "Add the Keyfleet connector in Claude's settings, with the address " <>
         KeyfleetWeb.PublicDocuments.url("/mcp") <> ", and sign in to Keyfleet when Claude asks."}

  def runtime_step(slug),
    do:
      {"Prompt",
       "Install the Keyfleet skill from keyfleet.ai/agents/#{slug}/skill.md and follow it."}

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
      variant="secondary"
      phx-click="open_send_agent"
      aria-haspopup="dialog"
    >
      Send your agent
    </Regent.Primitives.button>

    <Regent.Structure.dialog
      :if={@open}
      id={"#{@id}-dialog"}
      class="send-agent"
      phx-hook="ModalDialog"
      phx-mounted={JS.ignore_attributes(["open", "style"])}
      data-close-event="close_send_agent"
      aria-labelledby={"#{@id}-title"}
    >
      <h2 id={"#{@id}-title"} tabindex="-1" data-modal-title>Invitation</h2>
      <p>
        Paste this to your agent.
        <Regent.Primitives.tip id={"#{@id}-tip"} label="About your agent">
          It looks around first and tells you what it could do there. Any Key, and any shard you
          give it, stay your call.
        </Regent.Primitives.tip>
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
        Your agent installs <a href={~p"/skill.md"}>keyfleet.ai/skill.md</a>
      </p>
    </Regent.Structure.dialog>
    """
  end
end
