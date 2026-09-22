defmodule KeyFleetWeb.Plugs.AgentJoin do
  @moduledoc "Captures the bounded signed join request before any parser or method rewrite."
  @behaviour Plug
  @behaviour Siwa.AgentAuthPlug.Hooks
  import Plug.Conn
  alias KeyFleet.Actors.Agent

  @path "/api/v1/agent/join/status"
  @max_body 4096
  @proof_headers ~w(signature signature-input content-digest x-siwa-receipt x-key-id x-timestamp x-agent-wallet-address x-agent-chain-id)

  @impl Plug
  def init(opts), do: opts

  @impl Plug
  def call(conn, _opts) do
    if Enum.map(Enum.take(conn.path_info, 3), &URI.decode/1) == ["api", "v1", "agent"],
      do: authenticate(conn),
      else: conn
  end

  defp authenticate(conn) do
    with true <- conn.method == "POST" and conn.request_path == @path and conn.query_string == "",
         [type] <- get_req_header(conn, "content-type"),
         {:ok, "application", "json", _} <- Plug.Conn.Utils.media_type(type),
         %Plug.Conn.Unfetched{} <- conn.body_params do
      case read_body(conn, length: @max_body, read_length: @max_body + 1) do
        {:ok, raw, conn} -> verify_body(conn, raw)
        {:more, _raw, conn} -> deny(conn, %{reason: :invalid_request})
        {:error, _reason} -> deny(conn, %{reason: :invalid_request})
      end
    else
      _ -> deny(conn, %{reason: :invalid_request})
    end
  end

  defp verify_body(conn, raw) do
    with true <- byte_size(raw) > 0 and byte_size(raw) <= @max_body,
         {:ok, %{"name" => name, "declared_harness" => harness} = params} <- Jason.decode(raw),
         true <- map_size(params) == 2 and is_binary(name) and is_binary(harness) do
      conn = %{conn | body_params: params, params: params} |> assign(:raw_body, raw)

      Siwa.AgentAuthPlug.call(conn,
        client: KeyFleet.SiwaBroker,
        hooks: __MODULE__,
        audience: "keyfleet",
        signed_path: :path_only,
        body: :always
      )
    else
      _ -> deny(conn, %{reason: :invalid_request})
    end
  end

  @impl Siwa.AgentAuthPlug.Hooks
  def before_verify(conn, _headers) do
    names = Enum.map(conn.req_headers, fn {name, _} -> String.downcase(name) end)

    valid? =
      conn.method == "POST" and conn.request_path == @path and conn.query_string == "" and
        is_binary(conn.assigns[:raw_body]) and
        Enum.all?(@proof_headers, &(Enum.count(names, fn name -> name == &1 end) == 1)) and
        not Enum.any?(names, fn name ->
          (String.starts_with?(name, "x-agent-") or String.starts_with?(name, "x-siwa-")) and
            name not in @proof_headers
        end)

    if valid?, do: {:ok, nil}, else: {:error, %{reason: :invalid_request}}
  end

  @impl Siwa.AgentAuthPlug.Hooks
  def accept(
        conn,
        %{
          "verified" => true,
          "walletAddress" => wallet,
          "chainId" => 8453,
          "keyId" => wallet,
          "receiptExpiresAt" => expires,
          "requiredHeaders" => required_headers,
          "requiredCoveredComponents" => required_components,
          "coveredComponents" => covered_components,
          "principal" =>
            %{
              "kind" => "wallet",
              "wallet_address" => wallet,
              "chain_id" => 8453,
              "audience" => "keyfleet"
            } = principal
        } = data,
        _context
      )
      when map_size(data) == 9 and map_size(principal) == 4 and is_binary(expires) and
             is_list(required_headers) and is_list(required_components) and
             is_list(covered_components) do
    actor = %Agent{wallet_address: wallet, chain_id: 8453, audience: "keyfleet"}

    if Agent.valid?(actor),
      do: {:ok, assign(conn, :agent_actor, actor)},
      else: invalid_principal()
  end

  def accept(_conn, _data, _context), do: invalid_principal()
  defp invalid_principal, do: {:error, %{reason: :invalid_principal}}

  @impl Siwa.AgentAuthPlug.Hooks
  def deny(conn, metadata) do
    unavailable? =
      metadata[:reason] in [:broker_unavailable, :siwa_request_failed] or
        metadata[:siwa_status] in 500..599

    status = if unavailable?, do: 503, else: 401
    code = if status == 503, do: "authentication_unavailable", else: "unauthorized"

    conn
    |> put_resp_header("cache-control", "no-store")
    |> put_resp_content_type("application/json")
    |> send_resp(status, Jason.encode!(%{error: code}))
    |> halt()
  end

  def proof_headers, do: @proof_headers
end
