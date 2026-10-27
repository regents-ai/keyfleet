defmodule KeyfleetWeb.Components.ConfirmDialog do
  @moduledoc """
  The window a page asks in before a press that can't be undone, in the
  shared cut-corner dialog: the question, a line on what follows, Cancel, and
  the button that goes ahead, which the page draws inside it.

  The page holds what it is asking about and draws the window only while it
  does. The window opens with focus on the question. Cancel, Escape and the
  window closing any other way send `close`, so the page stops asking, and
  focus goes back to the button that opened it (`ModalDialog`).
  """
  use KeyfleetWeb, :html

  attr :id, :string, required: true
  attr :question, :string, required: true
  attr :about, :string, required: true, doc: "what follows the press"
  attr :close, :string, required: true, doc: "the event Cancel and Escape send"
  attr :shown, :string, required: true, doc: "what it asks about"
  slot :inner_block, required: true, doc: "the button that goes ahead"

  def confirm_dialog(assigns) do
    ~H"""
    <Regent.Structure.dialog
      id={@id}
      class="confirm-dialog"
      phx-hook="ModalDialog"
      phx-mounted={JS.ignore_attributes(["open", "style"])}
      data-close-event={@close}
      data-shown={@shown}
      aria-labelledby={"#{@id}-title"}
      aria-describedby={"#{@id}-about"}
    >
      <h2 id={"#{@id}-title"} tabindex="-1" data-modal-title>{@question}</h2>
      <p id={"#{@id}-about"}>{@about}</p>
      <div class="confirm-dialog__actions">
        <form method="dialog">
          <Regent.Primitives.button id={"#{@id}-cancel"} type="submit" variant="secondary">
            Cancel
          </Regent.Primitives.button>
        </form>
        {render_slot(@inner_block)}
      </div>
    </Regent.Structure.dialog>
    """
  end
end
