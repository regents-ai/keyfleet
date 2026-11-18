defmodule KeyfleetWeb.BodyReaderTest do
  # Costly failure: an agent's signed body of exactly its limit, sent in
  # chunks with no length, is refused as too large at the shared agent
  # address or the connector's. The site's reader is served on a real port,
  # so a body arrives in chunks as it does from an agent.
  use ExUnit.Case, async: true

  alias KeyfleetWeb.SignedAgentHelpers

  setup do
    reader =
      SignedAgentHelpers.serve!(:reader, fn conn, _opts ->
        {read, body, conn} = KeyfleetWeb.BodyReader.read_body(conn, length: 1_000_000)
        Plug.Conn.send_resp(conn, 200, "#{read} #{byte_size(body)}")
      end)

    %{reader: reader}
  end

  test "a signed body of exactly its limit is read whole however it arrives, and one byte more is not",
       c do
    signed = [{Siwa.Contract.signature_input_header(), "sig1=()"}]

    for {path, limit} <- [{"/api/agents/v1/pair", 4096}, {"/mcp", 1_000_000}] do
      exact = String.duplicate(" ", limit)
      over = exact <> " "
      pieces = [binary_part(exact, 0, 100), binary_part(exact, 100, limit - 100)]

      read =
        for body <- [
              exact,
              Stream.map([exact], & &1),
              Stream.map(pieces, & &1),
              over,
              Stream.map([over], & &1)
            ] do
          Req.post!(c.reader <> path, headers: signed, body: body, retry: false).body
        end

      assert {path, read} ==
               {path,
                [
                  "ok #{limit}",
                  "ok #{limit}",
                  "ok #{limit}",
                  "more #{limit + 1}",
                  "more #{limit + 1}"
                ]}
    end
  end
end
