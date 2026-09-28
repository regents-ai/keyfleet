defmodule KeyfleetWeb.RefusalHelpers do
  @moduledoc "What a refusal's body reads as once a JSON client decodes it."

  @doc "The body refusing a request with `code`."
  def refused(code), do: code |> KeyfleetWeb.Refusal.body() |> Jason.encode!() |> Jason.decode!()
end
