defmodule Keyfleet.Limits do
  @moduledoc """
  The named allowances in `config :keyfleet, :limits`, each spent through
  `Keyfleet.Accounts.RequestRateLimiter`.
  """

  alias Keyfleet.Accounts.RequestRateLimiter

  @doc "Spends one of `name`'s allowance for `who`: `:ok` or `:limited`."
  @spec spend(atom(), term()) :: :ok | :limited
  def spend(name, who) do
    case admit(name, who) do
      :ok -> :ok
      {:limited, _retry_after} -> :limited
    end
  end

  @doc """
  Spends one of `name`'s allowance for `who`: `:ok`, or `{:limited, seconds}`
  with the seconds until the allowance starts again.
  """
  @spec admit(atom(), term()) :: :ok | {:limited, pos_integer()}
  def admit(name, who) do
    config = config(name)
    limited(RequestRateLimiter.admit({name, who}, config[:limit], config[:window_seconds]))
  end

  @doc "What `admit/2` would answer for `who` now, spending none of `name`'s allowance."
  @spec check(atom(), term()) :: :ok | {:limited, pos_integer()}
  def check(name, who) do
    config = config(name)
    limited(RequestRateLimiter.check({name, who}, config[:limit], config[:window_seconds]))
  end

  defp limited({:ok, _budget}), do: :ok
  defp limited({:error, :rate_limited, budget}), do: {:limited, budget.reset}

  @doc "The seconds `name`'s allowance lasts before it starts again."
  @spec window(atom()) :: pos_integer()
  def window(name), do: config(name)[:window_seconds]

  defp config(name), do: :keyfleet |> Application.fetch_env!(:limits) |> Keyword.fetch!(name)
end
