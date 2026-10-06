defmodule KeyfleetWeb.AgentAvatarTest do
  @moduledoc """
  An agent's picture: the upload address holds exactly the picture it was
  started for, only real pictures within the limits are kept, an agent sets
  only its own picture, and a replaced picture is deleted from the bucket.
  """
  use KeyfleetWeb.ConnCase, async: false
  use Oban.Testing, repo: Keyfleet.Repo, prefix: "keyfleet_app"

  alias Keyfleet.Actors.Agent
  alias Keyfleet.Agents
  alias Keyfleet.Agents.{Avatar, AvatarBucket, DeleteAvatar}

  # The salt `KeyfleetWeb.AgentAvatarController` signs upload addresses with.
  @salt "agent avatar upload"

  setup do
    actor = actor()
    profile = Agents.ensure_profile!(%{name: "Astra", declared_harness: "Hermes"}, actor: actor)
    %{actor: actor, profile: profile}
  end

  # The address holds the picture: its exact bytes, length and type, for ten
  # minutes. Anything else changes nothing.
  test "an upload address takes only the picture it was started for", c do
    picture = png(64, 64)
    declared = declared(picture, "image/png")
    stub_bucket(self())

    other = png(64, 65)

    assert refusal(upload(c, ticket(c, declared), other, "image/png"), 422) == "avatar_mismatch"

    assert refusal(upload(c, ticket(c, %{declared | byte_size: 999}), picture, "image/png"), 422) ==
             "avatar_mismatch"

    assert refusal(upload(c, ticket(c, declared), picture, "image/webp"), 422) ==
             "avatar_mismatch"

    expired = ticket(c, declared, signed_at: System.system_time(:second) - 601)
    assert refusal(upload(c, expired, picture, "image/png"), 401) == "avatar_upload_expired"
    assert refusal(upload(c, "forged", picture, "image/png"), 401) == "avatar_upload_expired"

    refute_received {:bucket, _method, _path}
    assert Agents.get_my_profile!(actor: c.actor).avatar_key == nil

    conn = upload(c, ticket(c, declared), picture, "image/png")
    assert %{"avatar_url" => url} = json_response(conn, 200)
    key = Agents.get_my_profile!(actor: c.actor).avatar_key
    assert url == "https://keyfleet-avatars.storage.test/" <> key
    assert_received {:bucket, "PUT", "/keyfleet-avatars/" <> ^key}
  end

  # A PNG, JPEG or WebP of at most 512 KiB, each side 32 to 1,024 pixels.
  test "only pictures within the limits are taken" do
    for type <- ["image/png", "image/jpeg", "image/webp"],
        do: assert({:ok, _declared} = Avatar.declare(declared_params(1, type)))

    for type <- ["image/gif", "image/svg+xml", "text/plain"],
        do: assert(Avatar.declare(declared_params(1, type)) == :error)

    assert {:ok, _declared} = Avatar.declare(declared_params(512 * 1024, "image/png"))
    assert Avatar.declare(declared_params(512 * 1024 + 1, "image/png")) == :error

    for {width, height} <- [{32, 32}, {1024, 1024}, {32, 1024}] do
      picture = png(width, height)
      assert Avatar.check(picture, declared(picture, "image/png")) == :ok
    end

    for {width, height} <- [{31, 64}, {64, 31}, {1025, 64}, {64, 1025}] do
      picture = png(width, height)
      assert Avatar.check(picture, declared(picture, "image/png")) == {:error, :unreadable}
    end

    # A PNG named as a WebP, and bytes that are no picture at all.
    picture = png(64, 64)
    assert Avatar.check(picture, declared(picture, "image/webp")) == {:error, :unreadable}
    text = "<svg xmlns='http://www.w3.org/2000/svg'/>"
    assert Avatar.check(text, declared(text, "image/png")) == {:error, :unreadable}
  end

  test "a body longer than a picture may be is refused before it is read in full", c do
    picture = :binary.copy(<<0>>, 512 * 1024 + 1)
    declared = %{sha256: sha256(picture), byte_size: 512 * 1024, content_type: "image/png"}

    assert refusal(upload(c, ticket(c, declared), picture, "image/png"), 413) ==
             "request_too_large"
  end

  test "an agent sets and removes only its own picture", c do
    other = actor()
    Agents.ensure_profile!(%{name: "Other", declared_harness: "Hermes"}, actor: other)
    key = Avatar.new_key(c.profile.id, "image/png")

    assert {:error, %Ash.Error.Forbidden{}} = Agents.set_avatar(c.profile, key, actor: other)
    assert {:error, %Ash.Error.Forbidden{}} = Agents.remove_avatar(c.profile, actor: other)
    assert {:ok, %{avatar_key: ^key}} = Agents.set_avatar(c.profile, key, actor: c.actor)
  end

  # Each upload has its own key, so deleting a replaced one never touches the
  # picture now shown; a key already gone counts as deleted.
  test "a replaced or removed picture is deleted from the bucket, once or twice", c do
    first = Avatar.new_key(c.profile.id, "image/png")
    second = Avatar.new_key(c.profile.id, "image/webp")

    profile = Agents.set_avatar!(c.profile, first, actor: c.actor)
    refute_enqueued(worker: DeleteAvatar)

    profile = Agents.set_avatar!(profile, second, actor: c.actor)
    assert_enqueued(worker: DeleteAvatar, args: %{key: first})

    Agents.remove_avatar!(profile, actor: c.actor)
    assert_enqueued(worker: DeleteAvatar, args: %{key: second})

    stub_bucket(self(), %{"DELETE" => 204})
    assert :ok = perform_job(DeleteAvatar, %{key: first})
    assert_received {:bucket, "DELETE", "/keyfleet-avatars/" <> ^first}

    stub_bucket(self(), %{"DELETE" => 404})
    assert :ok = perform_job(DeleteAvatar, %{key: first})

    stub_bucket(self(), %{"DELETE" => 503})
    assert {:error, {:bucket_status, 503}} = perform_job(DeleteAvatar, %{key: second})
  end

  defp upload(c, ticket, bytes, type) do
    c.conn
    |> put_req_header("content-type", type)
    |> put(~p"/api/v1/avatar/upload/#{ticket}", bytes)
  end

  defp refusal(conn, status), do: json_response(conn, status)["error"]["code"]

  defp ticket(c, declared, options \\ []) do
    Phoenix.Token.sign(
      KeyfleetWeb.Endpoint,
      @salt,
      %{profile_id: c.profile.id, declared: declared, agent: Map.from_struct(c.actor)},
      options
    )
  end

  defp stub_bucket(test, statuses \\ %{}) do
    Req.Test.stub(AvatarBucket, fn conn ->
      send(test, {:bucket, conn.method, conn.request_path})
      Plug.Conn.send_resp(conn, Map.get(statuses, conn.method, 200), "")
    end)
  end

  defp declared(bytes, type),
    do: %{sha256: sha256(bytes), byte_size: byte_size(bytes), content_type: type}

  defp declared_params(size, type),
    do: %{"sha256" => String.duplicate("a", 64), "byte_size" => size, "content_type" => type}

  defp sha256(bytes), do: :crypto.hash(:sha256, bytes) |> Base.encode16(case: :lower)

  # A PNG's signature and header chunk, which say its size; enough for the
  # size check, which reads no further.
  defp png(width, height) do
    header = <<width::32, height::32, 8, 6, 0, 0, 0>>
    chunk = "IHDR" <> header
    <<0x89, "PNG\r\n", 0x1A, "\n", 13::32>> <> chunk <> <<:erlang.crc32(chunk)::32>>
  end

  defp actor do
    %Agent{
      wallet_address: "0x" <> Base.encode16(:crypto.strong_rand_bytes(20), case: :lower),
      chain_id: 8453,
      verification_method: :eoa_recovery,
      audience: "keyfleet"
    }
  end
end
