defmodule KeyfleetWeb.NotebookOpenHTML do
  @moduledoc """
  The page that sends a person's one-time notebook code to their fleet's
  notebook host (`KeyfleetWeb.NotebookOpenController`). Its one script sends
  the form as soon as the page loads, only when the person has just pressed
  Open notebooks in the workspace; without scripts, the button does. Anyone
  the notebook host sends here, from a saved output's address or after a
  refused code, is asked to press the button, so a browser that leaves out
  which site sent the form, or won't keep the notebook sign-in, is never sent
  round and round.
  """
  use KeyfleetWeb, :html

  def entry(assigns) do
    ~H"""
    <!DOCTYPE html>
    <html lang="en">
      <head>
        <meta charset="utf-8" />
        <meta name="viewport" content="width=device-width, initial-scale=1" />
        <title>Opening notebooks</title>
      </head>
      <body>
        <p :if={!@by_itself?}>Press the button to open the notebooks.</p>
        <form id="notebook-entry" method="post" action={@entry.action}>
          <input type="hidden" name="code" value={@entry.code} />
          <input type="hidden" name="to" value={@entry.to} />
          <button type="submit">Open notebooks</button>
        </form>
        <script :if={@by_itself?} nonce={@nonce}>
          document.getElementById("notebook-entry").submit()
        </script>
      </body>
    </html>
    """
  end
end
