defmodule KeyfleetWeb.RefusalHelpers do
  @moduledoc "What a refusal's body reads as once a JSON client decodes it."

  @doc "The body refusing a request with `code`."
  def refused(code), do: code |> KeyfleetWeb.Refusal.body() |> Jason.encode!() |> Jason.decode!()

  @doc """
  Whether `response` refuses a signed body that doesn't fit its operation,
  naming the fields the operation takes.
  """
  def misfit?(%{
        status: 422,
        body: %{"error" => %{"code" => "invalid_request", "hint" => "This operation takes " <> _}}
      }),
      do: true

  def misfit?(_response), do: false
end
