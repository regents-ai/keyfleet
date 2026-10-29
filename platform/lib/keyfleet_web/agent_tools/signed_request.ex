defmodule KeyfleetWeb.AgentTools.SignedRequest do
  @moduledoc """
  An agent tool's input as the signed request its browser tool sends, so the
  Claude connector's tool is checked and answered as that request is:
  `params/1` gives the request's JSON (its body with the names in its
  address), `check/2` checks its body as a signed request's is checked
  (`KeyfleetWeb.Plugs.SignedAgent.check_body/2`), and `result/1` turns the
  request's answer into the action's result.
  """

  alias Keyfleet.Capabilities
  alias KeyfleetWeb.AgentTools.Refused
  alias KeyfleetWeb.Plugs.SignedAgent

  @doc "The signed request's JSON for an action's `arguments`, leaving out those not given."
  @spec params(map()) :: map()
  def params(arguments), do: json(arguments)

  defp json(%{__struct__: _} = value), do: value

  defp json(%{} = map),
    do: for({key, value} <- map, not is_nil(value), into: %{}, do: {to_string(key), json(value)})

  defp json(list) when is_list(list), do: Enum.map(list, &json/1)
  defp json(value), do: value

  @doc """
  `:ok` when `params` fit the signed request of the browser tool named
  `tool`, or the refusal that request would be answered with. Each tool's
  action takes its address's names, so its request always has them.
  """
  @spec check(String.t(), map()) :: :ok | {:error, Exception.t()}
  def check(tool, params) do
    browser_tool = Enum.find(Capabilities.tools(), &(&1["name"] == tool))

    case Capabilities.request(browser_tool, params) do
      {:ok, "GET", _path, nil} -> :ok
      {:ok, _method, path, body} -> fits(path, body)
    end
  end

  defp fits(path, body) do
    case SignedAgent.check_body(path, body) do
      :ok ->
        :ok

      check ->
        {status, refusal} = SignedAgent.body_refusal(path, check)
        {:error, Refused.exception(status: status, body: refusal)}
    end
  end

  @doc "An answer, `{status, body, retry_after}`, as an action's result: its body or refusal."
  @spec result({pos_integer(), map(), pos_integer() | nil}) ::
          {:ok, map()} | {:error, Exception.t()}
  def result({status, body, _retry_after}) when status in 200..299, do: {:ok, body}

  def result({status, body, retry_after}),
    do: {:error, Refused.exception(status: status, body: body, retry_after: retry_after)}
end
