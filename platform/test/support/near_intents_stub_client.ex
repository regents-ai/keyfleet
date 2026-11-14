defmodule Keyfleet.Fundings.StubClient do
  @moduledoc """
  The NEAR Intents service as a test describes it, with `RegentNearIntents`'s
  shape. A quote answers the saved dry quote (1.651313840569386417635746 NEAR
  for 5 USDC, about 24 seconds) and, when not dry, a deposit address and a
  deadline; a status answers waiting for the deposit. A test changes either
  answer with `put_quote/1` or `put_status/1`, and every process it starts,
  such as a page, answers the same. Each quote asked is sent to the test as
  `{:near_quote, request}`, which `quotes/0` collects.
  """

  @fixture "test/support/fixtures/near_intents/quote.dry.json"
           |> File.read!()
           |> JSON.decode!()

  @doc "The saved dry quote, as the service answered it."
  def fixture, do: @fixture

  @doc "What every quote of the calling test answers from now on."
  def put_quote(answer), do: Process.put({__MODULE__, :quote}, answer)

  @doc "What every status read of the calling test answers from now on."
  def put_status(answer), do: Process.put({__MODULE__, :status}, answer)

  @doc "The quotes the calling test's processes asked since it last collected them."
  def quotes, do: collect([])

  def quote(request) do
    send(test_process(), {:near_quote, request})
    answer(:quote) || default_quote(request)
  end

  def status(_deposit_address) do
    answer(:status) ||
      {:ok, %{state: :pending_deposit, origin_tx: nil, destination_tx: nil, raw: %{}}}
  end

  defp default_quote(%{dry: dry}) do
    quote = @fixture["quote"]

    {:ok,
     %{
       amount_in: quote["amountIn"],
       amount_in_formatted: quote["amountInFormatted"],
       amount_out: quote["amountOut"],
       amount_out_formatted: quote["amountOutFormatted"],
       time_estimate_s: quote["timeEstimate"],
       deadline: if(dry, do: nil, else: "2026-11-14T23:00:00.000Z"),
       deposit_address: if(dry, do: nil, else: "deposit-stub-1"),
       raw: @fixture
     }}
  end

  defp collect(asked) do
    receive do
      {:near_quote, request} -> collect([request | asked])
    after
      0 -> Enum.reverse(asked)
    end
  end

  defp answer(kind) do
    Enum.find_value([self() | Process.get(:"$callers", [])], fn pid ->
      case Process.info(pid, :dictionary) do
        {:dictionary, dictionary} ->
          List.keyfind(dictionary, {__MODULE__, kind}, 0, {nil, nil}) |> elem(1)

        nil ->
          nil
      end
    end)
  end

  defp test_process, do: List.last([self() | Process.get(:"$callers", [])])
end
