defmodule KeyfleetWeb.PollTools do
  @moduledoc """
  What the browser tools on a fleet's polls pages do for a browser's own
  agent: read the polls, and start, join, leave and end one, ask its next
  question and vote, as the person signed in on the page. Each goes through
  `KeyfleetWeb.PollsLive.act/4`, as the page's own boxes and buttons do, and
  is turned down for the same reasons, in the same words. The page shows what
  changed the way it shows anyone else's.

  Every answer is `%{ok: true, ...}` with the fields the agent API answers, or
  `%{ok: false, error: %{code, message, hint}}`. `priv/tool_manifest.json`
  describes each tool; `assets/js/page_tools.ts` offers them.
  """

  alias Keyfleet.Polls
  alias KeyfleetWeb.PollJSON
  alias KeyfleetWeb.PollsLive
  alias KeyfleetWeb.ShellLive

  @list_tools ~w(list_polls start_poll)
  @poll_tools ~w(read_poll join_poll leave_poll end_poll open_round vote_in_round)
  @presses %{
    "start_poll" => :start,
    "join_poll" => :join,
    "leave_poll" => :leave,
    "end_poll" => :end,
    "open_round" => :ask,
    "vote_in_round" => :vote
  }

  @doc "The tools the polls pages offer."
  def tools, do: @list_tools ++ @poll_tools

  @doc "Answers one call of the named tool, against what the page shows now."
  def call(tool, input, socket) do
    {:reply, answer(tool, input, socket.assigns.polls, ShellLive.human_actor(socket)), socket}
  end

  # Every field a tool takes is a string, as the manifest describes it.
  defp answer(tool, input, page, actor) do
    if is_map(input) and Enum.all?(Map.values(input), &is_binary/1),
      do: answer_on_page(tool, input, page, actor),
      else: refusal("invalid_input", "Send an object of named fields, each a string.")
  end

  defp answer_on_page("list_polls", _input, %{kind: :list} = page, actor) do
    sessions = Polls.list_sessions!(page.fleet_id, actor: actor)
    %{ok: true, fleet_id: page.fleet_id, sessions: Enum.map(sessions, &PollJSON.session/1)}
  end

  defp answer_on_page("read_poll", _input, %{kind: :poll, session: %{} = session} = page, actor) do
    %{
      ok: true,
      session: PollJSON.session(session),
      rounds:
        page.fleet_id
        |> Polls.list_rounds!(session.id, actor: actor)
        |> Enum.map(&PollJSON.round/1)
    }
  end

  defp answer_on_page(tool, _input, _page, nil) when is_map_key(@presses, tool),
    do:
      refusal(
        "sign_in_required",
        "No one is signed in on this page, so nothing was changed.",
        "Ask the person to sign in, then call again."
      )

  defp answer_on_page(tool, _input, %{kind: :poll, session: nil}, _actor)
       when tool in @poll_tools,
       do: refusal("poll_unknown", "This fleet has no such poll.")

  defp answer_on_page(tool, input, %{kind: kind} = page, actor)
       when (kind == :list and tool == "start_poll") or (kind == :poll and tool in @poll_tools) do
    press = Map.fetch!(@presses, tool)

    case PollsLive.act(press, page, input, actor) do
      {:error, error} ->
        {code, message} = PollsLive.refusal(error, page.fleet_id, PollsLive.default_code(press))
        refusal(code, message)

      done ->
        done(press, done, page.fleet_id)
    end
  end

  defp answer_on_page(_tool, _input, _page, _actor),
    do:
      refusal(
        "not_on_page",
        "This page doesn't show that now.",
        "Check what the page shows, then call again."
      )

  defp done(press, {:ok, session}, fleet_id) when press in [:start, :end],
    do: %{ok: true, session: PollJSON.session(reload(fleet_id, session.id))}

  defp done(:join, {:ok, seat}, _fleet_id), do: %{ok: true, seat: PollJSON.seat(seat)}
  defp done(:leave, :ok, _fleet_id), do: %{ok: true}

  defp done(:ask, {:ok, round}, _fleet_id),
    do: %{ok: true, round: Keyfleet.Polls.Round.to_map(round)}

  defp done(:vote, {:ok, vote}, _fleet_id),
    do: %{
      ok: true,
      vote: %{key: vote.token_id, action: vote.action, reason: vote.reason, counted: vote.counted}
    }

  defp reload(fleet_id, session_id),
    do: Polls.get_session!(fleet_id, session_id, actor: %Keyfleet.Actors.System{})

  defp refusal(code, message, hint \\ "Check what the page shows, then call again."),
    do: %{ok: false, error: %{code: code, message: message, hint: hint}}
end
