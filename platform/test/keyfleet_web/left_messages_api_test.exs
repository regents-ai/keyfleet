defmodule KeyfleetWeb.LeftMessagesApiTest do
  # An agent leaving a message for the site's team over its own signed request
  # (`POST /api/v1/messages/{topic}`); the hosted tool `messages_leave` answers
  # the same, in KeyfleetWeb.McpConnectorTest:
  # - a paired agent with a profile leaves one and gets its receipt, 201, as
  #   itself whatever the body says about the sender;
  # - its operation_id answers 200 with the first receipt, and 409
  #   idempotency_conflict for other text;
  # - input the action cannot take is 422 invalid_message with details;
  # - an agent with no profile is 404 profile_not_found, and an unsigned
  #   request leaves nothing.
  use ExUnit.Case, async: false

  import Phoenix.ConnTest
  import Plug.Conn

  alias Keyfleet.{Agents, PairingHelpers}
  alias Keyfleet.LeftMessages.LeftMessage
  alias KeyfleetWeb.SignedAgentHelpers

  @endpoint KeyfleetWeb.Endpoint

  setup do
    owner =
      Ecto.Adapters.SQL.Sandbox.start_owner!(Keyfleet.Repo,
        shared: true,
        isolation: "REPEATABLE READ"
      )

    on_exit(fn -> Ecto.Adapters.SQL.Sandbox.stop_owner(owner) end)

    secret = :crypto.strong_rand_bytes(32)
    SignedAgentHelpers.start_broker!(self(), secret)
    {:ok, signer} = Siwa.LocalSigner.new()
    agent = PairingHelpers.pair_wallet!(String.downcase(signer.address))

    %{
      secret: secret,
      signer: signer,
      agent: agent,
      from: {198, 51, 100, :rand.uniform(250)}
    }
  end

  test "a signed agent leaves a message as itself, and its operation_id answers it again", c do
    profile = Agents.ensure_profile!(%{name: "Scout", declared_harness: "test"}, actor: c.agent)
    key = Ecto.UUID.generate()

    body = %{
      "body" => "Hello team",
      "reply_to" => "agent@example.com",
      "operation_id" => key
    }

    left = post!(c, "agents", body)
    assert left.status == 201
    assert %{"receipt" => %{"id" => id, "topic" => "agents", "inserted_at" => _}} = json(left)

    message = Enum.find(saved(), &(&1.id == id))
    assert {message.body, message.reply_to} == {"Hello team", "agent@example.com"}
    assert {message.agent_profile_id, message.sender_name} == {profile.id, "Scout"}
    assert message.human_account_id == c.agent.human_account_id

    again = post!(c, "agents", body)
    assert again.status == 200
    assert json(again)["receipt"]["id"] == id

    other = post!(c, "agents", %{"body" => "Other text", "operation_id" => key})
    assert other.status == 409
    assert json(other)["error"]["code"] == "idempotency_conflict"
  end

  test "input the action cannot take is refused with what to change", c do
    Agents.ensure_profile!(%{name: "Scout", declared_harness: "test"}, actor: c.agent)
    count = count()

    too_long =
      post!(c, "agents", %{"body" => String.duplicate("a", 2001), "operation_id" => uuid()})

    assert too_long.status == 422

    assert %{"code" => "invalid_message", "details" => [%{"field" => "body"}]} =
             json(too_long)["error"]

    assert post!(c, "Agents!", %{"body" => "Hi", "operation_id" => uuid()}).status == 422

    # A sender named in the body is no field of a message: the request is refused.
    named = %{"body" => "Hi", "operation_id" => uuid(), "sender_name" => "Someone else"}
    assert post!(c, "agents", named).status == 422

    assert count() == count
  end

  test "an agent with no profile, or an unsigned request, leaves nothing", c do
    count = count()

    missing = post!(c, "agents", %{"body" => "Hi", "operation_id" => uuid()})
    assert missing.status == 404
    assert json(missing)["error"]["code"] == "profile_not_found"

    unsigned =
      %{build_conn() | remote_ip: c.from}
      |> put_req_header("content-type", "application/json")
      |> post(
        "/api/v1/messages/agents",
        Jason.encode!(%{"body" => "Hi", "operation_id" => uuid()})
      )

    assert unsigned.status == 401
    assert count() == count
  end

  defp post!(c, topic, body) do
    path = "/api/v1/messages/" <> topic
    raw = Jason.encode!(body)
    request = SignedAgentHelpers.sign(c.signer, c.secret, "www.example.com", "POST", path, raw)

    request.headers
    |> Enum.reduce(%{build_conn() | remote_ip: c.from}, fn {name, value}, conn ->
      put_req_header(conn, name, value)
    end)
    |> dispatch(@endpoint, :post, path, raw)
  end

  # Every message saved, read past the policy that keeps them for the admins.
  defp saved, do: Ash.read!(LeftMessage, authorize?: false)
  defp count, do: length(saved())
  defp json(conn), do: Jason.decode!(conn.resp_body)
  defp uuid, do: Ecto.UUID.generate()
end
