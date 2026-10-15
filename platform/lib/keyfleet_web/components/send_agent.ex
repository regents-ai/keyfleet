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

  @doc "The instruction a fleet's page offers: the guide, then the fleet named `name`."
  def fleet_instruction(name), do: "#{@lead} Then look at the #{name} fleet."

  @doc "A public treasury review; copying this never authorizes a wallet action."
  def treasury_instruction(fleet_id) do
    "Read https://keyfleet.ai/agents.md, then review " <>
      "https://keyfleet.ai/api/v1/fleets/#{fleet_id}/treasury. " <>
      "Use read_treasury through native WebMCP if available; otherwise use that public HTTP read. " <>
      "Report the indexed balances, their timestamp and any catching-up warning. " <>
      "Separate treasury funds from Key rewards. Name which transport you used. " <>
      "Do not sign or submit wallet transactions."
  end

  @doc "A workspace review using the agent's own access, with a draft before publication."
  def workspace_instruction(fleet_id) do
    "Read https://keyfleet.ai/agents.md, then review " <>
      "https://keyfleet.ai#{Keyfleet.Fleets.path(fleet_id)}/workspace. " <>
      "Use your existing paired signer for member details; never borrow my browser session. " <>
      "If access is refused, report the error and stop. Summarize current work and suggest one next step. " <>
      "Draft a member note with evidence links, and ask me before publishing it or starting a notebook session. " <>
      "Do not submit wallet transactions."
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
      variant="secondary"
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
      data-close-event="close_send_agent"
      aria-labelledby={"#{@id}-title"}
    >
      <h2 id={"#{@id}-title"} tabindex="-1" data-modal-title>Send your agent</h2>
      <p>
        Paste this to your agent.
        <Regent.Primitives.tip id={"#{@id}-tip"} label="What your agent does">
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
        What your agent installs: <a href={~p"/skill.md"}>keyfleet.ai/skill.md</a>
      </p>
    </dialog>
    """
  end
end
