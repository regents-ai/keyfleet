defmodule RegentNearIntentsTest do
  use ExUnit.Case, async: true

  @quote_fixture "test/support/fixtures/near_intents/quote.dry.json"
                 |> File.read!()
                 |> JSON.decode!()

  test "a dry quote asks the one route and answers the service's price" do
    Req.Test.stub(RegentNearIntents, fn conn ->
      {:ok, body, conn} = Plug.Conn.read_body(conn)
      send(self(), {:asked, conn.method, conn.request_path, JSON.decode!(body)})
      Req.Test.json(conn, @quote_fixture)
    end)

    assert {:ok, quote} =
             RegentNearIntents.quote(%{
               usdc_amount: 5_000_000,
               recipient: "0x1111111111111111111111111111111111111111",
               refund_to: "test.near",
               dry: true
             })

    assert quote.amount_in == "1651313840569386417635746"
    assert quote.amount_in_formatted == "1.651313840569386417635746"
    assert quote.amount_out == "5000000"
    assert quote.time_estimate_s == 24
    assert quote.deposit_address == nil

    assert_received {:asked, "POST", "/v0/quote", body}
    asked = @quote_fixture["quoteRequest"]

    for field <-
          ~w(dry swapType originAsset destinationAsset depositType recipientType refundType amount recipient refundTo) do
      assert body[field] == asked[field]
    end
  end

  test "a status names the state and the transactions on each chain" do
    Req.Test.stub(RegentNearIntents, fn conn ->
      assert conn.query_string == "depositAddress=deposit-1"

      Req.Test.json(conn, %{
        "status" => "SUCCESS",
        "swapDetails" => %{
          "originChainTxHashes" => [%{"hash" => "near-tx", "explorerUrl" => ""}],
          "destinationChainTxHashes" => [%{"hash" => "0xbase", "explorerUrl" => ""}]
        }
      })
    end)

    assert {:ok, %{state: :success, origin_tx: "near-tx", destination_tx: "0xbase"}} =
             RegentNearIntents.status("deposit-1")
  end

  test "a refusal is an error with the service's message" do
    Req.Test.stub(RegentNearIntents, fn conn ->
      conn |> Plug.Conn.put_status(400) |> Req.Test.json(%{"message" => "amount is too low"})
    end)

    assert {:error, %{reason: :rejected, message: "amount is too low"}} =
             RegentNearIntents.status("deposit-1")
  end
end
