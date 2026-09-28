defmodule KeyfleetWeb.ErrorJSON do
  @moduledoc """
  This module is invoked by your endpoint in case of errors on JSON requests.

  See config/config.exs.
  """

  alias KeyfleetWeb.PublicDocuments

  # An error no route answers itself, such as an unknown /api address or a
  # body that is not JSON, is `{"error": {"code", "message", "hint"}}`: the
  # status message from the template name, "404.json" becoming "Not Found",
  # its code in snake case, and where to read about the supported requests.
  def render(template, _assigns) do
    template
    |> Phoenix.Controller.status_message_from_template()
    |> RegentAgentAccess.Recovery.json(
      "See #{PublicDocuments.url("/docs")} and #{PublicDocuments.url("/openapi.json")} for supported requests."
    )
  end
end
