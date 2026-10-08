defmodule KeyfleetWeb.PollTools do
  @moduledoc """
  What the browser tools on a fleet's polls pages do for a browser's own
  agent: read the polls, start one, read one, vote in it and end it, as the
  person signed in on the page. Each press goes through
  `KeyfleetWeb.PollsLive.act/4`, as the page's own boxes and buttons do, and
  is turned down for the same reasons, in the same words. The page shows what
  changed the way it shows anyone else's.

  Every answer is `%{ok: true, ...}` with the fields the agent API answers, or
  `%{ok: false, error: %{code, message, hint}}`; a Key at its daily limit is
  also told `retry_after`, the seconds until it may start another poll.
  `priv/tool_manifest.json` describes each tool; `assets/js/page_tools.ts`
  offers them.
  """

  alias Keyfleet.Polls
  alias KeyfleetWeb.PollJSON
  alias KeyfleetWeb.PollRefusal
  alias KeyfleetWeb.PollsLive
  alias KeyfleetWeb.ShellLive

  @list_tools ~w(list_polls start_poll)
  @poll_tools ~w(read_poll vote_in_poll end_poll)
  @presses %{"start_poll" => :start, "vote_in_poll" => :vote, "end_poll" => :end}

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

  defp answer_on_page("list_polls", _input, %{kind: :list} = page, _actor),
    do: %{ok: true, fleet_id: page.fleet_id, polls: Enum.map(page.polls, &PollJSON.poll/1)}

  # The fleet's Key holders also read their own Key's vote and, once the poll
  # closes, every vote.
  defp answer_on_page("read_poll", _input, %{kind: :poll, poll: %{} = poll} = page, _actor) do
    answer = %{ok: true, poll: PollJSON.poll(poll)}

    if page.voter,
      do:
        Map.merge(answer, %{
          my_vote: page.my_vote && PollJSON.vote(page.my_vote),
          votes: Enum.map(page.votes, &PollJSON.vote/1)
        }),
      else: answer
  end

  defp answer_on_page(tool, _input, _page, nil) when is_map_key(@presses, tool),
    do:
      refusal(
        "sign_in_required",
        "No one is signed in on this page, so nothing was changed.",
        "Ask the person to sign in, then call again."
      )

  defp answer_on_page(tool, _input, %{kind: :poll, poll: nil}, _actor)
       when tool in @poll_tools,
       do: refusal("poll_unknown", "This fleet has no such poll.")

  defp answer_on_page(tool, input, %{kind: kind} = page, actor)
       when (kind == :list and tool == "start_poll") or (kind == :poll and tool in @poll_tools) do
    press = Map.fetch!(@presses, tool)

    case PollsLive.act(press, page, input, actor) do
      {:ok, done} -> done(press, done, page.fleet_id)
      {:error, error} -> refused(error, page.fleet_id, press)
    end
  end

  defp answer_on_page(_tool, _input, _page, _actor),
    do:
      refusal(
        "not_on_page",
        "This page doesn't show that now.",
        "Check what the page shows, then call again."
      )

  defp done(:vote, vote, _fleet_id), do: %{ok: true, vote: PollJSON.vote(vote)}

  defp done(_start_or_end, poll, fleet_id),
    do: %{ok: true, poll: PollJSON.poll(reload(fleet_id, poll.id))}

  defp reload(fleet_id, poll_id),
    do: Polls.get_poll!(fleet_id, poll_id, actor: %Keyfleet.Actors.System{})

  defp refused(error, fleet_id, press) do
    {code, message} = PollsLive.refusal(error, fleet_id, PollsLive.default_code(press))

    case PollRefusal.retry_after(error) do
      nil ->
        refusal(code, message)

      seconds ->
        code
        |> refusal(message, "Start another poll after retry_after seconds.")
        |> Map.put(:retry_after, seconds)
    end
  end

  defp refusal(code, message, hint \\ "Check what the page shows, then call again."),
    do: %{ok: false, error: %{code: code, message: message, hint: hint}}
end
