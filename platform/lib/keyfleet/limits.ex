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

    case RequestRateLimiter.admit({name, who}, config[:limit], config[:window_seconds]) do
      {:ok, _budget} -> :ok
      {:error, :rate_limited, budget} -> {:limited, budget.reset}
    end
  end

  @doc "The seconds `name`'s allowance lasts before it starts again."
  @spec window(atom()) :: pos_integer()
  def window(name), do: config(name)[:window_seconds]

  defp config(name), do: :keyfleet |> Application.fetch_env!(:limits) |> Keyword.fetch!(name)
end
