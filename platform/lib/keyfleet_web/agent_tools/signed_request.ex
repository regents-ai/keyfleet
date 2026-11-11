defmodule KeyfleetWeb.AgentTools.SignedRequest do
  @moduledoc """
  An agent tool's input as the signed request its browser tool sends, so the
  Claude connector's tool is checked and answered as that request is:
  `params/2` gives the request's JSON (its body with the names in its
  address), `check/2` checks its body as a signed request's is checked
  (`KeyfleetWeb.Plugs.SignedAgent.check_body/2`), and `result/1` turns the
  request's answer into the action's result.
  """

  alias Keyfleet.Capabilities
  alias Keyfleet.Fleets
  alias KeyfleetWeb.AgentTools.Refused
  alias KeyfleetWeb.Plugs.SignedAgent
  alias KeyfleetWeb.Refusal

  @doc """
  The signed request's JSON for an action's `arguments`, leaving out those not
  given, with the `fixed` fields its browser tool always sends. Within an
  argument every value is kept as sent, null included.
  """
  @spec params(map(), map()) :: map()
  def params(arguments, fixed) do
    arguments
    |> Enum.reject(fn {_name, value} -> is_nil(value) end)
    |> Map.new(fn {name, value} -> {to_string(name), json(value)} end)
    |> Map.merge(fixed)
  end

  defp json(%{__struct__: _} = value), do: value
  defp json(%{} = map), do: Map.new(map, fn {key, value} -> {to_string(key), json(value)} end)
  defp json(list) when is_list(list), do: Enum.map(list, &json/1)
  defp json(value), do: value

  @doc """
  `:ok` when `params` fit the signed request of the browser tool named
  `tool`, or the refusal that request would be answered with. Each tool's
  action takes its address's names, so its request always has them. A
  request that fits but names a coming-soon fleet is refused as every agent
  request about one is (`KeyfleetWeb.Plugs.FleetComingSoon`), so nothing is
  read or written. A public read and a picture's upload send no signed
  request, so the action's arguments and its answer are their whole check.
  """
  @spec check(String.t(), map()) :: :ok | {:error, Exception.t()}
  def check(tool, params) do
    case Enum.find(Capabilities.tools(), &(&1["name"] == tool)) do
      %{"authentication" => unsigned} when unsigned in ["public", "upload_address"] -> :ok
      browser_tool -> signed(browser_tool, params)
    end
  end

  defp signed(browser_tool, params) do
    with :ok <- fits(Capabilities.request(browser_tool, params)), do: opened(params)
  end

  defp fits({:ok, "GET", _path, nil}), do: :ok
  defp fits({:ok, _method, path, body}), do: fits(path, body)

  defp fits(path, body) do
    case SignedAgent.check_body(path, body) do
      :ok ->
        :ok

      check ->
        {status, refusal} = SignedAgent.body_refusal(path, check)
        {:error, Refused.exception(status: status, body: refusal)}
    end
  end

  defp opened(%{"fleet_id" => fleet_id}) do
    if Fleets.coming_soon?(fleet_id, Fleets.get_fleet!(fleet_id)),
      do: {:error, Refused.exception(status: 404, body: Refusal.body("fleet_coming_soon"))},
      else: :ok
  end

  defp opened(_params), do: :ok

  @doc "An answer, `{status, body, retry_after}`, as an action's result: its body or refusal."
  @spec result({pos_integer(), map(), pos_integer() | nil}) ::
          {:ok, map()} | {:error, Exception.t()}
  def result({status, body, _retry_after}) when status in 200..299, do: {:ok, body}

  def result({status, body, retry_after}),
    do: {:error, Refused.exception(status: status, body: body, retry_after: retry_after)}
end
