defmodule KeyfleetWeb.ErrorMD do
  @moduledoc """
  Public recovery instructions without private request or exception details.
  A missing page points to the nearest real one: the fleet list for an address
  under `/fleets/`, a fleet's own Markdown for an address under the fleet's
  pages (`/classic/1.md`), the agent guide for anything else.
  """

  alias Keyfleet.Fleets
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

  defp nearest(%Plug.Conn{request_path: path}) do
    page = String.replace_suffix(path, ".md", "")

    case Enum.find(Fleets.catalog(), &under?(page, &1.path)) do
      %{id: id, name: name} -> {name, "/fleets/#{id}.md"}
      nil -> {"the agent guide", "/llms.txt"}
    end
  end

  defp under?(page, fleet_path),
    do: page == fleet_path or String.starts_with?(page, fleet_path <> "/")
end
