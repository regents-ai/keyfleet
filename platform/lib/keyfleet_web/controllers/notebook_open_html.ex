defmodule KeyfleetWeb.NotebookOpenHTML do
  @moduledoc """
  The page that sends a person's one-time notebook code to their fleet's
  notebook host (`KeyfleetWeb.NotebookOpenController`). Its one script sends
  the form as soon as the page loads; without scripts, the button does. When
  the notebook host sent the person back here, the page says so and waits for
  the button, so a browser that leaves out which site sent the form is never
  sent round and round.
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
        <p :if={!@by_itself?}>The notebooks didn’t open. Press the button to try again.</p>
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
