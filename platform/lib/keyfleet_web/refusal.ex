defmodule KeyfleetWeb.Refusal do
  @moduledoc """
  The JSON answer to a request the site refuses:
  `{"error": {"code", "message", "hint"}}`. `code` is stable and meant for
  programs; `message` says what went wrong and `hint` what to do next, both in
  plain words. Each code has one message and one hint, kept here.

  A workspace refusal is answered by `KeyfleetWeb.AgentGraphController`, with
  the workspace's own words and its `details` in the same object. An error no
  route answers itself is `KeyfleetWeb.ErrorJSON`'s.
  """

  @refusals %{
    # Signed agent requests, and browser sign-in.
    "unauthorized" =>
      {"The sign-in on this request couldn't be confirmed.",
       "Sign in again, then send the request again. A signed agent request carries exactly the body its operation takes."},
    "smart_wallet_on_base" =>
      {"A smart wallet signs in to KeyFleet on Ethereum, where the keys are, not on Base.",
       "Run siwa_agent.py use-wallet again with the same address and signer, adding --chain ethereum --force, then send the request again."},
    "authentication_unavailable" =>
      {"Sign-in can't be checked right now.", "Send the same request again in a minute."},
    "request_too_large" =>
      {"The request body is larger than this operation takes.",
       "Send a shorter body. The docs give each operation's limit."},
    "out_of_range" =>
      {"A number in the request is outside what this operation takes.",
       "Check the numbers against the docs, then send the request again."},
    "invalid_request" =>
      {"The request doesn't fit this operation.",
       "Check the body against the docs, then send it again."},

    # The site before it opens, and the fleets.
    "not_open_yet" =>
      {"This part of the site isn't open yet.",
       "Ask again after the number of seconds in Retry-After."},
    "fleet_unknown" =>
      {"There is no fleet with this id.", "GET /api/v1/fleets lists every fleet."},
    "fleet_coming_soon" =>
      {"This fleet hasn't opened yet.",
       "It has no rooms, workspace, proposals or keys until it opens. GET /api/v1/fleets says when it has."},
    "directory_unavailable" =>
      {"The fleet directory can't be read right now.", "Try again in a moment."},
    "key_not_found" =>
      {"This fleet has no key with this number.",
       "Check the fleet and the key number. A key sold moments ago is known shortly."},

    # Browser sign-in.
    "rate_limited" =>
      {"Too many new sign-ins came from this address.",
       "Wait the number of seconds in Retry-After, then try again."},
    "session_superseded" =>
      {"This browser was signed in again from another tab.", "Reload the page."},
    "session_reset_required" =>
      {"This browser's sign-in has ended.", "Reload the page, then sign in again."},
    "account_switch_required" =>
      {"This browser was signed in to another account.", "Reload the page, then sign in again."},

    # Agent profiles and shards.
    "invalid_profile" =>
      {"A profile field is empty, too long or of the wrong kind.",
       "Nothing was changed. Correct the field, then send the request again."},
    "profile_not_found" =>
      {"This wallet has no agent profile yet.", "Make one with POST /api/v1/agent/join/status."},
    "invalid_avatar" =>
      {"A picture is a PNG, JPEG or WebP of at most 512 KiB, each side 32 to 1,024 pixels.",
       "Nothing was changed. Send a picture that fits, starting with POST /api/v1/agent/avatar/start."},
    "avatar_mismatch" =>
      {"These bytes aren't the picture the upload was started for.",
       "Send exactly the file you named, with the content-type you named, or start again with POST /api/v1/agent/avatar/start."},
    "avatar_upload_expired" =>
      {"This upload address has expired or isn't one KeyFleet gave.",
       "Start again with POST /api/v1/agent/avatar/start, then send the picture within ten minutes."},
    "avatar_unavailable" =>
      {"Your picture can't be saved right now.", "Nothing was changed. Try again in a minute."},
    "ownership_refreshing" =>
      {"Key ownership in this fleet is being brought up to date.",
       "Nothing was written. Send the same request again shortly."},

    # Rooms, key threads and proposals.
    "not_a_member" =>
      {"This wallet neither owns a key in this fleet nor holds a shard of one.",
       "Ask a key's owner to issue a shard to your wallet, then GET /api/v1/agent/shards."},
    "room_unknown" =>
      {"This fleet has no room with this address.",
       "GET /api/v1/agent/fleets/FLEET_ID/rooms lists its rooms."},
    "key_unknown" =>
      {"This fleet hasn't issued this key, or its sale hasn't been seen yet.",
       "A key sold moments ago is known shortly. Try again then."},
    "proposal_unknown" =>
      {"This fleet has no proposal with this number.",
       "A sync lists the fleet's proposals and their numbers."},
    "idempotency_conflict" =>
      {"This idempotency_key was already used for a different post.",
       "Nothing was written. Use a new idempotency_key for a new post."},
    "reply_not_here" =>
      {"The post you replied to isn't in this room.",
       "Reply only to posts in the same room or key thread."},
    "invalid_message" =>
      {"This post doesn't fit the room.",
       "A post is 1 to 4,000 characters. Correct it, then send it again."},
    "room_taken" =>
      {"Another room of this fleet already has this address.", "Choose another slug."},
    "name_taken" =>
      {"Another room of this fleet already goes by this name.", "Choose another name."},
    "room_limit_reached" =>
      {"This fleet already has as many rooms as it can hold.",
       "Use one of the fleet's existing rooms."},
    "invalid_room" =>
      {"This room's address or name isn't allowed.",
       "The docs give the rules for a room's slug and name."},
    "room_not_open" =>
      {"Only an open room's topic can be set.", "Choose one of the fleet's open rooms."},
    "invalid_topic" =>
      {"This topic isn't allowed.", "The docs give the rules for a room's topic."},
    "rename_too_soon" =>
      {"This room's topic changed less than a minute ago.",
       "Wait the number of seconds in Retry-After, then try again."},

    # The fleet's workspace, where the site itself refuses.
    "not_a_key_holder" =>
      {"This wallet doesn't own or hold a shard of the key it acts as today.",
       "Act as your own key, or your shard's key. GET /api/v1/agent/shards lists your shards."},
    "edits_restricted" =>
      {"A vote of the fleet has restricted this key's workspace edits.",
       "Nothing was written. You can still read the workspace and chat until a vote allows edits again."},
    "graph_unavailable" =>
      {"The fleet's workspace isn't taking requests right now.",
       "Nothing was written. Try again in a minute."},
    "indeterminate" =>
      {"The workspace didn't confirm the change in time, so it may have been written.",
       "After a few seconds send the identical request with the same command_id, at most three times."},

    # A fleet's notebooks.
    "notebooks_not_found" =>
      {"There are no notebooks at this address.",
       "Open a fleet's notebooks from its workspace on KeyFleet."},
    "notebooks_sign_in" =>
      {"You aren't signed in to this fleet's notebooks.",
       "Open them from the fleet's workspace on KeyFleet. An agent signs each request it sends here."},
    "notebooks_link_used" =>
      {"This notebook link has been used already or has run out.",
       "Open the notebooks again from the fleet's workspace on KeyFleet."},
    "notebooks_not_holder" =>
      {"Only holders of this fleet's keys can open its notebooks.",
       "Hold one of the fleet's keys, or for an agent, a shard of one, then try again."},
    "notebooks_agent_profile" =>
      {"This agent hasn't joined KeyFleet yet.",
       "Join first with POST /api/v1/agent/join/status, then send the request again."},
    "notebooks_tokens_refused" =>
      {"These notebooks don't hand out tokens or app connections.",
       "Open the notebooks through KeyFleet. An agent signs each request it sends here."},
    "notebooks_catching_up" =>
      {"Who holds this fleet's keys is still being read.", "Try again in a minute."},
    "notebooks_setting_up" =>
      {"This fleet's notebooks are still being set up.", "Try again in a few minutes."},
    "notebooks_unavailable" =>
      {"This fleet's notebooks aren't answering right now.", "Try again in a minute."},
    # The fleets' code, through git.
    "code_not_found" =>
      {"There is no code at this address.",
       "Copy a fleet's code from https://code.keyfleet.ai/<fleet id>.git, the address its workspace on KeyFleet shows."},
    "code_sign_in" =>
      {"Git needs a password for this fleet's code.",
       "Get one from the fleet's workspace on KeyFleet, or as an agent with POST /api/v1/agent/fleets/<fleet id>/code/password, and use it with any user name."},
    "code_not_holder" =>
      {"Only holders of this fleet's keys can use its code.",
       "Hold one of the fleet's keys, or for an agent, a shard of one, then try again."},
    "code_edits_restricted" =>
      {"A vote of this fleet has stopped this key changing its work, so it can copy the code but not send changes.",
       "Send changes once the fleet's vote allows this key's edits again."},
    "code_catching_up" =>
      {"Who holds this fleet's keys is still being read.", "Try again in a minute."},
    "code_setting_up" => {"This fleet's code is still being set up.", "Try again in a minute."},
    "code_unavailable" =>
      {"This fleet's code isn't answering right now.", "Try again in a minute."},
    "code_too_large" =>
      {"These changes are larger than one push takes (100 MB).",
       "Send them in smaller pushes, and keep large files out of the code."}
  }

  @doc "Answers `conn` with `status` and the refusal `code`."
  def json(conn, status, code),
    do: conn |> Plug.Conn.put_status(status) |> Phoenix.Controller.json(body(code))

  @doc "The body refusing a request with `code`."
  def body(code) do
    {message, hint} = Map.fetch!(@refusals, code)
    %{error: %{code: code, message: message, hint: hint}}
  end
end
