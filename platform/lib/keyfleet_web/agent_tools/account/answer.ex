defmodule KeyfleetWeb.AgentTools.Account.Answer do
  @moduledoc """
  An agent's own profile and its person's account, the same over its signed
  requests and as the Claude connector's tools (`KeyfleetWeb.AgentTools.Account`):
  reading, making and setting the status of its profile (`:profile`, `:join`,
  `:edit_profile`), setting and removing its picture (`:avatar_start`,
  `:avatar_upload`, `:avatar_remove`), and its person's Points (`:points`).
  Each answer is `{status, body, retry_after}`, `retry_after` in seconds past a
  limit and otherwise nil; `params` is the signed request's JSON body.

  A picture is set in two steps because it is larger than a signed request
  can carry. `:avatar_start` names it: its SHA-256, its length and its type.
  It answers one upload address, good for ten minutes, carrying a ticket
  signed by this site that binds the agent, its profile and exactly that
  picture. `upload/3` takes the bytes for that ticket; the ticket is its
  permission, so the upload is not signed itself, and `:avatar_upload` sends
  them to the address as base64. `:avatar_remove` takes the picture away.
  Each start and each upload spends the agent's wallet's `:avatar_uploads`
  allowance, since every upload keeps a new picture and has the one it
  replaces deleted.

  A profile is answered with the agent's page in the agent registry, whether
  a World ID-verified person stands behind it and how many agents that person
  stands behind, as its profile saved them.

  `:leave_message` leaves a private message for the site's team, the same over
  `POST /api/v1/messages/{topic}` (`KeyfleetWeb.AgentMessageController`). A
  new message answers 201 with its receipt; a retry with the operation_id of a
  message the agent already left answers 200 with that message's receipt and
  leaves nothing (`Keyfleet.LeftMessages.LeftMessage.AgentLeave`). Its
  `params` hold the topic the address names, and the messages each address
  may leave are counted under the `waiter` the caller passes,
  `KeyfleetWeb.ClientAddress.key/1`'s key.
  """

  require Logger

  alias Keyfleet.Actors.Agent
  alias Keyfleet.Agents
  alias Keyfleet.Agents.Avatar
  alias Keyfleet.LeftMessages
  alias Keyfleet.LeftMessages.Refused, as: MessageRefused
  alias Keyfleet.Limits
  alias Keyfleet.Points.Board
  alias Keyfleet.SharedReading
  alias KeyfleetWeb.{ClientAddress, Endpoint, PointsEntries, Refusal}
  alias RegentAgents.HumanBacking
  alias RegentPoints.Rules

  @points_off "Earning Points is off on this site."

  # Leaving a message has words of its own: the room codes' words are about posts.
  @message_refusals %{
    "invalid_message" =>
      {422, "The message could not be left.",
       "details says why. Send {\"body\": \"…\", \"reply_to\": \"…\", \"operation_id\": \"<uuid>\"}: a body of 1 to 2,000 characters, an optional reply_to of up to 200, and a UUID you keep when retrying, to a topic of lowercase letters, numbers and hyphens. After 10 messages in an hour, wait."},
    "idempotency_conflict" =>
      {409, "This operation_id was already used for another message.",
       "Send a new UUID as operation_id for a new message. Keep an operation_id only to retry the same message."},
    "messages_unavailable" =>
      {503, "The message could not be left right now.", "Try again in a moment."}
  }

  @salt "agent avatar upload"
  @ticket_seconds 10 * 60
  @uploads "/api/v1/avatar/upload/"
  # The ticket is signed, not sealed, so it names the agent and nothing the
  # SIWA service said about it.
  @ticket_actor_fields [
    :wallet_address,
    :chain_id,
    :verification_method,
    :audience,
    :credential_ref,
    :pairing_id,
    :privy_user_id,
    :human_account_id
  ]

  @doc """
  Answers `op` for `actor`; nothing here waits, so the waiter only names the
  address a message for the team counts against.
  """
  @spec answer(atom(), map(), Agent.t(), term()) ::
          {pos_integer(), map(), pos_integer() | nil}
  def answer(:join, %{"name" => name, "declared_harness" => harness}, actor, _waiter) do
    case Agents.ensure_profile(%{name: name, declared_harness: harness}, actor: actor) do
      {:ok, profile} -> profile(profile)
      {:error, _error} -> refusal(422, "invalid_profile")
    end
  end

  def answer(:profile, _params, actor, _waiter) do
    case Agents.get_my_profile(actor: actor) do
      {:ok, nil} -> refusal(404, "profile_not_found")
      {:ok, profile} -> profile(profile)
      {:error, _error} -> refusal(503, "profile_unavailable")
    end
  end

  def answer(:edit_profile, params, actor, _waiter) do
    with {:ok, profile} when not is_nil(profile) <- Agents.get_my_profile(actor: actor),
         {:ok, profile} <- Agents.edit_my_profile(profile, params, actor: actor) do
      profile(profile)
    else
      {:ok, nil} -> refusal(404, "profile_not_found")
      {:error, _error} -> refusal(422, "invalid_profile")
    end
  end

  def answer(:points, _params, %{human_account_id: nil}, _waiter),
    do: refusal(403, "person_not_here")

  # The same figures the Points page shows, the board included: unavailable
  # until the board every reader shares has been read once.
  def answer(:points, _params, actor, _waiter) do
    with {:ok, summary} <- RegentPoints.summary(actor: actor),
         {:ok, %{reading: %{} = board}} <- SharedReading.fetch(Board.key()) do
      open? = Rules.active() != []

      summary
      |> PointsEntries.answer(board, actor.human_account_id, open?)
      |> with_note(!open?, @points_off)
      |> ok()
    else
      _unavailable -> refusal(503, "account_unavailable")
    end
  end

  def answer(:avatar_start, params, actor, _waiter) do
    with :ok <- Limits.admit(:avatar_uploads, actor.wallet_address),
         {:ok, declared} <- Avatar.declare(params),
         {:ok, %{id: profile_id}} <- Agents.get_my_profile(actor: actor) do
      ticket =
        Phoenix.Token.sign(Endpoint, @salt, %{
          profile_id: profile_id,
          declared: declared,
          agent: Map.take(actor, @ticket_actor_fields)
        })

      ok(%{
        upload_url: Endpoint.url() <> @uploads <> ticket,
        method: "PUT",
        content_type: declared.content_type,
        expires_at: DateTime.utc_now() |> DateTime.add(@ticket_seconds) |> DateTime.to_iso8601()
      })
    else
      {:limited, seconds} -> limited(seconds)
      :error -> refusal(422, "invalid_avatar")
      {:ok, nil} -> refusal(404, "profile_not_found")
      {:error, _error} -> refusal(503, "profile_unavailable")
    end
  end

  # The bytes go to the address the start answered, on this site only, as
  # the browser tool sends them.
  def answer(:avatar_upload, %{"upload_url" => url} = params, _actor, _waiter) do
    with {:ok, ticket} <- ticket(url),
         {:ok, upload} <- upload(ticket, params["content_type"]) do
      case Base.decode64(params["bytes_base64"], ignore: :whitespace, padding: false) do
        {:ok, bytes} -> keep(upload, bytes)
        :error -> refusal(422, "invalid_request")
      end
    else
      :not_here -> refusal(401, "avatar_upload_expired")
      refused -> refused
    end
  end

  def answer(:avatar_remove, _params, actor, _waiter) do
    case Agents.get_my_profile(actor: actor) do
      {:ok, nil} ->
        refusal(404, "profile_not_found")

      {:ok, profile} ->
        ok(%{avatar_url: Avatar.url(Agents.remove_avatar!(profile, actor: actor))})

      {:error, _error} ->
        refusal(503, "profile_unavailable")
    end
  end

  def answer(:leave_message, %{"topic" => topic} = params, actor, waiter) do
    case LeftMessages.agent_leave_message(
           topic,
           Map.take(params, ["body", "reply_to", "operation_id"]),
           actor: actor,
           context: %{client_key: ClientAddress.client_key(waiter)}
         ) do
      {:ok, %{receipt: receipt, replayed: false}} ->
        {201, %{receipt: receipt}, nil}

      {:ok, %{receipt: receipt, replayed: true}} ->
        ok(%{receipt: receipt})

      {:error, %Ash.Error.Invalid{errors: errors} = error} ->
        message_invalid(error, Enum.find(errors, &is_struct(&1, MessageRefused)))

      {:error, %module{}} ->
        # Only the kind of failure: an Ash error's message carries the input.
        Logger.error("Leaving a message for the team failed: #{inspect(module)}")
        message_refusal("messages_unavailable")
    end
  end

  @doc """
  The upload the `ticket` was started for, sent as `content_type`, before its
  bytes are read: `{:ok, upload}`, for `keep/2`, or the refusal. The ticket is
  the permission; the agent it names is checked as it stands now, and the
  upload spends its allowance.
  """
  @spec upload(String.t(), term()) ::
          {:ok, map()} | {pos_integer(), map(), pos_integer() | nil}
  def upload(ticket, content_type) do
    with {:ok, %{profile_id: profile_id, declared: declared, agent: agent}} <-
           Phoenix.Token.verify(Endpoint, @salt, ticket, max_age: @ticket_seconds),
         actor = struct!(Agent, agent),
         {:paired, true} <- {:paired, Agent.valid?(actor)},
         :ok <- Limits.admit(:avatar_uploads, actor.wallet_address),
         {:type, true} <- {:type, content_type == declared.content_type} do
      {:ok, %{actor: actor, profile_id: profile_id, declared: declared}}
    else
      {:error, _reason} -> refusal(401, "avatar_upload_expired")
      {:paired, false} -> refusal(403, "agent_not_paired")
      {:limited, seconds} -> limited(seconds)
      {:type, false} -> refusal(422, "avatar_mismatch")
    end
  end

  @doc """
  Keeps `bytes` as the picture of an `upload/2`: its new `avatar_url`, or the
  refusal. `:too_large` is a body longer than a picture may be, refused
  unread, and `:unreadable` one that stopped coming.
  """
  @spec keep(map(), binary() | :too_large | :unreadable) ::
          {pos_integer(), map(), pos_integer() | nil}
  def keep(_upload, :too_large), do: refusal(413, "request_too_large")
  def keep(_upload, :unreadable), do: refusal(503, "avatar_unavailable")

  def keep(upload, bytes) do
    if byte_size(bytes) > Avatar.max_bytes(),
      do: refusal(413, "request_too_large"),
      else: store(upload, bytes)
  end

  defp store(%{actor: actor, profile_id: profile_id, declared: declared}, bytes) do
    case Agents.store_avatar(actor, profile_id, declared, bytes) do
      {:ok, profile} -> ok(%{avatar_url: Avatar.url(profile)})
      {:error, :mismatch} -> refusal(422, "avatar_mismatch")
      {:error, :unreadable} -> refusal(422, "invalid_avatar")
      {:error, :profile_not_found} -> refusal(404, "profile_not_found")
      {:error, _reason} -> refusal(503, "avatar_unavailable")
    end
  end

  # The ticket in an upload address on this site, resolved against the site's
  # own address as a browser resolves it, with nothing asked after it.
  defp ticket(url) when is_binary(url) do
    site = URI.parse(Endpoint.url())
    address = URI.merge(site, url)

    with true <- {address.scheme, address.port} == {site.scheme, site.port},
         true <- String.downcase(address.host || "") == site.host,
         true <- address.query in [nil, ""],
         @uploads <> ticket when ticket != "" <- address.path do
      {:ok, URI.decode(ticket)}
    else
      _elsewhere -> :not_here
    end
  rescue
    # A ticket whose escapes are not ones.
    ArgumentError -> :not_here
  end

  defp ticket(_url), do: :not_here

  defp message_invalid(_error, %MessageRefused{code: "profile_not_found"}),
    do: refusal(404, "profile_not_found")

  defp message_invalid(_error, %MessageRefused{code: code}), do: message_refusal(code)

  defp message_invalid(error, nil) do
    {status, body, nil} = message_refusal("invalid_message")
    {status, put_in(body, [:error, :details], details(error)), nil}
  end

  defp message_refusal(code) do
    {status, message, hint} = Map.fetch!(@message_refusals, code)
    {status, %{error: %{code: code, message: message, hint: hint}}, nil}
  end

  # Each refused field and why, in the words the page's own form shows.
  defp details(%Ash.Error.Invalid{errors: errors}) do
    errors
    |> Enum.filter(&AshPhoenix.FormData.Error.impl_for/1)
    |> Enum.flat_map(&List.wrap(AshPhoenix.FormData.Error.to_form_error(&1)))
    |> Enum.map(fn {field, message, values} ->
      %{field: field, message: Enum.reduce(values, message, &fill/2)}
    end)
  end

  defp fill({key, value}, message) when is_binary(value) or is_number(value),
    do: String.replace(message, "%{#{key}}", to_string(value))

  defp fill(_value, message), do: message

  defp limited(seconds), do: {429, Refusal.body("avatar_limit_reached"), seconds}

  defp ok(body), do: {200, body, nil}
  defp refusal(status, code), do: {status, Refusal.body(code), nil}

  defp profile(profile) do
    profile
    |> HumanBacking.describe()
    |> Map.merge(%{
      registry_listing: profile.registry_url,
      profile:
        profile
        |> Map.take([
          :id,
          :wallet_address,
          :name,
          :declared_harness,
          :proficiencies,
          :interests,
          :service_ideas,
          :current_status,
          :status_updated_at,
          :last_activity_at
        ])
        |> Map.put(:avatar_url, Avatar.url(profile))
    })
    |> ok()
  end

  defp with_note(answer, true, note), do: Map.put(answer, :note, note)
  defp with_note(answer, false, _note), do: answer
end
