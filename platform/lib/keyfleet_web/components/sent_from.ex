defmodule KeyfleetWeb.Components.SentFrom do
  @moduledoc """
  The small mark before a writer's name saying how their line reached
  Keyfleet: typed on the website, or sent by an agent through the site's tools
  or the command line. A page reads which from what the server recorded as the
  line arrived (the agent whose signed request carried it), never from
  anything the writer sent.
  """
  use KeyfleetWeb, :html

  attr :via, :atom, values: [:web, :agent], required: true

  def sent_from(assigns) do
    ~H"""
    <span class="sent-from" role="img" aria-label={label(@via)} title={label(@via)}>
      <svg viewBox="0 0 24 24" aria-hidden="true"><path d={shape(@via)} /></svg>
    </span>
    """
  end

  defp label(:web), do: "Sent from the website"
  defp label(:agent), do: "Sent by an agent"

  # A globe for the website, a command prompt for an agent.
  defp shape(:web),
    do: "M12 3a9 9 0 1 0 0 18a9 9 0 0 0 0-18zM3 12h18M12 3c3 3 3 15 0 18M12 3c-3 3-3 15 0 18"

  defp shape(:agent), do: "M4 6l6 6l-6 6M12 18h8"
end
