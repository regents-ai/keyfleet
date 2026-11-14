defmodule RegentNearIntents do
  @moduledoc """
  The NEAR Intents 1Click service (https://1click.chaindefuser.com), for one
  route: NEAR in, an exact amount of USDC out on Base. It only asks: for the
  assets it knows, for a price or a deposit address, and for how a deposit
  stands. It keeps nothing and moves nothing; whoever pays sends NEAR from
  their own wallet to the deposit address a quote with `dry: false` answers.

  Errors are `{:error, %{reason: atom, message: String.t()}}`.
  """

  @origin "nep141:wrap.near"
  @usdc_on_base "nep141:base-0x833589fcd6edb6e08f4c7c32d4f71b54bda02913.omft.near"
  # How long the service has to fill a quote once asked.
  @deadline_s 30 * 60

  @states %{
    "PENDING_DEPOSIT" => :pending_deposit,
    "INCOMPLETE_DEPOSIT" => :pending_deposit,
    "KNOWN_DEPOSIT_TX" => :processing,
    "PROCESSING" => :processing,
    "SUCCESS" => :success,
    "REFUNDED" => :refunded,
    "FAILED" => :failed
  }

  @doc "Every asset the service swaps."
  def tokens do
    with {:ok, assets} <- request(method: :get, url: "/v0/tokens") do
      {:ok,
       Enum.map(assets, fn asset ->
         %{
           asset_id: asset["assetId"],
           symbol: asset["symbol"],
           blockchain: asset["blockchain"],
           decimals: asset["decimals"],
           price: asset["price"]
         }
       end)}
    end
  end

  @doc """
  What `usdc_amount` USDC (base units) at `recipient` on Base costs in NEAR,
  refunded to the NEAR account `refund_to` if the swap fails. With
  `dry: false` the answer carries the deposit address to send the NEAR to.
  """
  def quote(%{usdc_amount: amount, recipient: recipient, refund_to: refund_to, dry: dry})
      when is_integer(amount) and amount > 0 and is_boolean(dry) do
    body = %{
      dry: dry,
      depositMode: "SIMPLE",
      swapType: "EXACT_OUTPUT",
      slippageTolerance: 100,
      originAsset: @origin,
      depositType: "ORIGIN_CHAIN",
      destinationAsset: @usdc_on_base,
      amount: Integer.to_string(amount),
      refundTo: refund_to,
      refundType: "ORIGIN_CHAIN",
      recipient: recipient,
      recipientType: "DESTINATION_CHAIN",
      deadline: DateTime.utc_now() |> DateTime.add(@deadline_s) |> DateTime.to_iso8601()
    }

    with {:ok, %{"quote" => quote} = raw} <- request(method: :post, url: "/v0/quote", json: body) do
      {:ok,
       %{
         amount_in: quote["amountIn"],
         amount_in_formatted: quote["amountInFormatted"],
         amount_out: quote["amountOut"],
         amount_out_formatted: quote["amountOutFormatted"],
         time_estimate_s: quote["timeEstimate"],
         deadline: quote["deadline"],
         deposit_address: quote["depositAddress"],
         raw: raw
       }}
    end
  end

  @doc "How the deposit to `deposit_address` stands."
  def status(deposit_address) when is_binary(deposit_address) do
    with {:ok, raw} <-
           request(method: :get, url: "/v0/status", params: [depositAddress: deposit_address]),
         {:ok, state} <- state(raw["status"]) do
      details = raw["swapDetails"] || %{}

      {:ok,
       %{
         state: state,
         origin_tx: first_hash(details["originChainTxHashes"]),
         destination_tx: first_hash(details["destinationChainTxHashes"]),
         raw: raw
       }}
    end
  end

  defp state(status) do
    case Map.fetch(@states, status) do
      {:ok, state} -> {:ok, state}
      :error -> {:error, %{reason: :unknown_status, message: "Unknown status #{inspect(status)}"}}
    end
  end

  defp first_hash([%{"hash" => hash} | _rest]), do: hash
  defp first_hash(_none), do: nil

  defp request(options) do
    config = Application.get_env(:keyfleet, __MODULE__, [])

    [base_url: "https://1click.chaindefuser.com", retry: false, receive_timeout: 15_000]
    |> Keyword.merge(options)
    |> Keyword.merge(Keyword.get(config, :req_options, []))
    |> Req.request()
    |> case do
      {:ok, %Req.Response{status: 200, body: body}} ->
        {:ok, body}

      {:ok, %Req.Response{status: status, body: body}} ->
        {:error, %{reason: :rejected, message: message(body, status)}}

      {:error, exception} ->
        {:error, %{reason: :unreachable, message: Exception.message(exception)}}
    end
  end

  defp message(%{"message" => message}, _status) when is_binary(message), do: message
  defp message(_body, status), do: "The service answered #{status}"
end
