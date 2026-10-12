defmodule Keyfleet.Limits do
  @moduledoc """
  The named allowances in `config :keyfleet, :limits`, each spent through
  `Keyfleet.Accounts.RequestRateLimiter`.
  """

  alias Keyfleet.Accounts.RequestRateLimiter

  @doc "Spends one of `name`'s allowance for `who`: `:ok` or `:limited`."
  @spec spend(atom(), term()) :: :ok | :limited
  def spend(name, who) do
    config = :keyfleet |> Application.fetch_env!(:limits) |> Keyword.fetch!(name)

    case RequestRateLimiter.admit({name, who}, config[:limit], config[:window_seconds]) do
      {:ok, _budget} -> :ok
      {:error, :rate_limited, _budget} -> :limited
    end
  end
end
