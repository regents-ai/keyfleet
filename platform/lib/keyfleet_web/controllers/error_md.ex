defmodule KeyfleetWeb.ErrorMD do
  @moduledoc """
  Public recovery instructions without private request or exception details.
  A missing page points to the nearest real one: the fleet list for an address
  under `/fleets/`, the agent guide for anything else.
  """

  alias KeyfleetWeb.PublicDocuments

  def render("404" <> _format, assigns) do
    {label, path} = nearest(assigns[:conn])
    "# Not Found\n\nNothing is at this address. Read [#{label}](#{PublicDocuments.url(path)}).\n"
  end

  def render(template, _assigns) do
    links =
      for {label, path} <- PublicDocuments.recovery_links(),
          do: {label, PublicDocuments.url(path)}

    template
    |> Phoenix.Controller.status_message_from_template()
    |> RegentAgentAccess.Recovery.markdown(links)
  end

  defp nearest(%Plug.Conn{path_info: ["fleets" | _]}), do: {"every fleet", "/fleets.md"}
  defp nearest(_conn), do: {"the agent guide", "/llms.txt"}
end
