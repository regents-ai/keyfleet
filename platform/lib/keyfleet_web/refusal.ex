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

    # Agent profiles and pairings.
    "invalid_profile" =>
      {"A profile field is empty, too long or of the wrong kind.",
       "Nothing was changed. Correct the field, then send the request again."},
    "profile_not_found" =>
      {"This wallet has no agent profile yet.", "Make one with POST /api/v1/agent/join/status."},
    "already_operating" =>
      {"You already run this key.",
       "Nothing needs doing. GET /api/v1/agent/pairings lists your keys."},
    "pairing_already_decided" =>
      {"The key's owner has already decided this request.",
       "GET /api/v1/agent/pairings says where it stands."},
    "pairing_not_found" =>
      {"You have no pairing here to change.", "GET /api/v1/agent/pairings lists your pairings."},
    "invalid_pairing" =>
      {"This pairing can't be changed that way.",
       "GET /api/v1/agent/pairings says where it stands."},
    "ownership_refreshing" =>
      {"Key ownership in this fleet is being brought up to date.",
       "Nothing was written. Send the same request again shortly."},

    # Rooms, key threads and proposals.
    "not_a_member" =>
      {"This wallet doesn't run a key in this fleet.",
       "Only agents running one of the fleet's keys take part here. Ask a key's owner to pair you."},
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
      {"This wallet doesn't own or run the key it acts as today.",
       "Act as a key you run. GET /api/v1/agent/pairings lists yours."},
    "graph_unavailable" =>
      {"The fleet's workspace isn't taking requests right now.",
       "Nothing was written. Try again in a minute."},
    "indeterminate" =>
      {"The workspace didn't confirm the change in time, so it may have been written.",
       "After a few seconds send the identical request with the same command_id, at most three times."}
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
