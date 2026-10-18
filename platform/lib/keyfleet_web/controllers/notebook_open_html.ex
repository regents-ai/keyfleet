defmodule KeyfleetWeb.NotebookOpenHTML do
  @moduledoc """
  The page that sends a person's one-time notebook code to their fleet's
  notebook host (`KeyfleetWeb.NotebookOpenController`). Its one script sends
  the form as soon as the page loads; without scripts, the button does.
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
        <form id="notebook-entry" method="post" action={@entry.action}>
          <input type="hidden" name="code" value={@entry.code} />
          <input type="hidden" name="to" value={@entry.to} />
          <button type="submit">Open notebooks</button>
        </form>
        <script nonce={@nonce}>
          document.getElementById("notebook-entry").submit()
        </script>
      </body>
    </html>
    """
  end
end
