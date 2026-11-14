defmodule Keyfleet.Budgets.Https do
  @moduledoc """
  A link a purchase keeps is an https address with a host, of at most 2,048
  characters, as a direct message's link part is (`Keyfleet.Dms.Part`).
  Validates the action argument `field`; a link not given passes.
  """
  use Ash.Resource.Validation

  @max_url 2_048

  @impl true
  def supports(_opts), do: [Ash.ActionInput]

  @impl true
  def validate(input, opts, _context) do
    field = Keyword.fetch!(opts, :field)

    case Ash.ActionInput.get_argument(input, field) do
      nil ->
        :ok

      url ->
        if https?(url),
          do: :ok,
          else:
            {:error,
             field: field, message: "is an https address of at most #{@max_url} characters"}
    end
  end

  defp https?(url) do
    match?(
      {:ok, %URI{scheme: "https", host: host}} when is_binary(host) and host != "",
      URI.new(url)
    ) and
      byte_size(url) <= @max_url
  end
end
