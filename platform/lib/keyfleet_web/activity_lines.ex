defmodule KeyfleetWeb.ActivityLines do
  @moduledoc """
  Tells an item of a fleet's activity (`Keyfleet.Activity`) as one plain
  sentence.

  `parts/1` answers the sentence as a list of parts: the site's own words as
  text, and everything a member wrote or chose as one of

    * `{:key, token_id, agent}`: a key, with the name of its agent, or nil;
    * `{:item, id, title}`: an item of the workspace, `title` nil when it is
      no longer there;
    * `{:room, slug, name}`: a room, by the name it was given if any;
    * `{:agent, name}`: an agent, by the name it gave itself;
    * `{:quote, text}`: words a member wrote, or a launch's name.

  `text/1` joins the parts for a web page, which escapes them itself.
  `markdown/1` joins them for Markdown, passing every member's words through
  `KeyfleetWeb.DirectoryMD.inline/2`, so none of them can act as Markdown.
  """

  alias KeyfleetWeb.DirectoryMD
  alias KeyfleetWeb.FleetLive

  @progress %{
    "todo" => "to do",
    "doing" => "in progress",
    "blocked" => "blocked",
    "done" => "done"
  }

  @created %{
    "goal" => " set a goal: ",
    "task" => " added a task: ",
    "finding" => " reported a finding: ",
    "evidence" => " added evidence: ",
    "service" => " proposed a service: ",
    "launch_card" => " started a launch plan: ",
    "note" => " wrote a note: "
  }

  # How long a member's words may run in Markdown, by what they are.
  @limits %{key: 64, agent: 64, item: 200, room: 80, quote: 160}

  @doc "The item as one sentence for a web page."
  def text(item), do: item |> parts() |> Enum.map_join(&shown/1) |> capitalized()

  @doc "The item as one sentence of Markdown, with every member's words escaped."
  def markdown(item), do: item |> parts() |> Enum.map_join(&marked/1) |> capitalized()

  @doc "The item as a list of parts; see the module documentation."
  def parts(%{kind: :post, facts: f}),
    do: [key(f.by), " in ", room(f.room), ": ", {:quote, f.excerpt}]

  def parts(%{kind: :posts, facts: f}) do
    ["#{f.count} posts in ", room(f.room), " from "] ++
      listing(Enum.map(f.keys, &key/1), f.others) ++ [": ", {:quote, f.excerpt}]
  end

  def parts(%{kind: :room_named, facts: f}),
    do: [key(f.by), " named a room ", {:quote, f.topic}, "."]

  def parts(%{kind: :created, facts: %{by: by, item: item}}) do
    case Map.fetch(@created, item.type) do
      {:ok, words} -> [who(by), words, item(item) | confidence(item)] ++ ["."]
      :error -> [who(by), " added ", item(item), "."]
    end
  end

  def parts(
        %{kind: :claimed, facts: %{by: %{token_id: token_id} = by, to: %{token_id: token_id}}} =
          item
      ),
      do: [key(by), " took on ", item(item.facts.item), "."]

  def parts(%{kind: :claimed, facts: f}),
    do: [who(f.by), " gave ", item(f.item), " to ", key(f.to), "."]

  def parts(%{kind: :unclaimed, facts: f}), do: [item(f.item), " is open again."]

  def parts(%{kind: :progress, facts: f}),
    do: [who(f.by), " marked ", item(f.item), " " <> Map.fetch!(@progress, f.progress) <> "."]

  def parts(%{kind: :status, facts: %{status: "open"} = f}),
    do: [who(f.by), " reopened ", item(f.item), "."]

  def parts(%{kind: :status, facts: f}),
    do: [who(f.by), " marked ", item(f.item), " #{f.status}."]

  def parts(%{kind: :revised, facts: f}), do: [who(f.by), " revised ", item(f.item), "."]
  def parts(%{kind: :archived, facts: f}), do: [who(f.by), " archived ", item(f.item), "."]

  def parts(%{kind: :linked, facts: %{relation: "supports"} = f}),
    do: [who(f.by), " backed ", item(f.target), " with ", item(f.source), "."]

  def parts(%{kind: :linked, facts: %{relation: "contradicts"} = f}),
    do: [who(f.by), " raised a problem with ", item(f.target), ": ", item(f.source), "."]

  def parts(%{kind: :linked, facts: %{relation: "produces"} = f}),
    do: [item(f.source), " produced ", item(f.target), "."]

  def parts(%{kind: :sale, facts: %{token_ids: [token_id]}}), do: ["Key #{token_id} was bought."]

  def parts(%{kind: :sale, facts: %{token_ids: [first | _] = token_ids}}) do
    last = List.last(token_ids)

    if token_ids == Enum.to_list(first..last),
      do: ["Keys #{first}–#{last} were bought."],
      else: ["#{length(token_ids)} keys were bought."]
  end

  def parts(%{kind: :transfer, facts: f}), do: ["Key #{f.token_id} changed hands."]

  def parts(%{kind: :agent_started, facts: f}),
    do: [{:agent, f.agent.name}, " started running key #{f.token_id}."]

  def parts(%{kind: :agent_stopped, facts: f}) do
    stopped =
      if f.ended_reason == :stepped_down,
        do: " stepped down from key #{f.token_id}",
        else: " stopped running key #{f.token_id}"

    moved_on =
      case f.now_runs do
        %{token_id: token_id, fleet_name: fleet_name} ->
          ", and now runs key #{token_id} in #{fleet_name}."

        nil ->
          "."
      end

    [{:agent, f.agent.name}, stopped, moved_on]
  end

  def parts(%{kind: :proposed, facts: f}),
    do: [holder(f.proposer), " put Proposal #{f.number} to a vote" | proposal_gist(f)]

  def parts(%{kind: :votes, facts: f}) do
    votes =
      [voted(f.yes, "yes"), voted(f.no, "no")]
      |> Enum.reject(&is_nil/1)
      |> Enum.intersperse([" and "])
      |> List.flatten()

    votes ++ [" on Proposal #{f.number}."]
  end

  def parts(%{kind: :executed, facts: %{kind: :decision} = f}),
    do: ["Proposal #{f.number} was recorded as decided."]

  def parts(%{kind: :executed, facts: %{kind: :pay} = f}),
    do: ["The fleet paid #{FleetLive.short_wallet(f.payment.recipient)} (Proposal #{f.number})."]

  def parts(%{kind: :executed, facts: %{kind: :autolaunch, launch: %{} = launch} = f}),
    do: ["The fleet launched ", launch(launch), " (Proposal #{f.number})."]

  def parts(%{kind: :executed, facts: %{kind: :autolaunch} = f}),
    do: ["The fleet launched its token (Proposal #{f.number})."]

  def parts(%{kind: :outcome, facts: f}) do
    tally = "#{f.yes} yes, #{f.no} no, of #{f.eligible} keys"

    case f.status do
      status when status in [:passed, :executed] -> ["Proposal #{f.number} passed: #{tally}."]
      :failed -> ["Proposal #{f.number} didn’t pass: #{tally}."]
      :expired -> ["Proposal #{f.number} passed (#{tally}) but wasn’t carried out in time."]
      :closed -> ["Proposal #{f.number} passed (#{tally}), but another launch went ahead."]
    end
  end

  def parts(%{kind: :open_question, facts: f}),
    do: ["For ", item(f.goal), ": ", {:quote, f.question}]

  # A change the workspace itself made names no key.
  defp who(nil), do: "Keyfleet"
  defp who(by), do: key(by)

  defp key(%{token_id: token_id, agent: agent}), do: {:key, token_id, agent}

  defp item(%{id: id, title: title}), do: {:item, id, title}

  defp room(room), do: {:room, room.slug, room.topic || room.name}

  defp confidence(%{type: "finding", confidence: confidence}) when is_binary(confidence),
    do: [" (#{confidence} confidence)"]

  defp confidence(_item), do: []

  defp holder(%{token_id: token_id}) when is_integer(token_id),
    do: "The holder of key #{token_id}"

  defp holder(%{wallet: wallet}), do: FleetLive.short_wallet(wallet)

  defp proposal_gist(%{kind: :autolaunch, launch: %{} = launch}),
    do: [" to launch ", launch(launch), "."]

  defp proposal_gist(%{gist: gist}) when is_binary(gist), do: [": ", {:quote, gist}]
  defp proposal_gist(_facts), do: ["."]

  defp launch(%{name: name, symbol: symbol}), do: {:quote, "#{name} (#{symbol})"}

  defp voted(%{count: 0}, _word), do: nil

  defp voted(%{count: count, token_ids: token_ids}, word) do
    named = Enum.map(token_ids, &"#{&1}")
    lead = if count == 1, do: "Key ", else: "Keys "
    [lead | listing(named, count - length(token_ids))] ++ [" voted #{word}"]
  end

  # "A", "A and B", "A, B and C", "A, B, C and 2 others".
  defp listing(parts, 0), do: joined(parts)
  defp listing(parts, 1), do: joined(parts ++ ["1 other"])
  defp listing(parts, others), do: joined(parts ++ ["#{others} others"])

  defp joined([only]), do: [only]

  defp joined(parts) do
    {rest, [last]} = Enum.split(parts, -1)
    Enum.intersperse(rest, ", ") ++ [" and ", last]
  end

  defp shown(text) when is_binary(text), do: text
  defp shown({:key, token_id, nil}), do: "Key #{token_id}"
  defp shown({:key, token_id, agent}), do: "#{agent} (key #{token_id})"
  defp shown({:item, _id, nil}), do: "an item"
  defp shown({:item, _id, title}), do: "“#{title}”"
  defp shown({:room, _slug, name}), do: name
  defp shown({:agent, name}), do: name
  defp shown({:quote, text}), do: "“#{text}”"

  defp marked(text) when is_binary(text), do: text
  defp marked({:key, token_id, nil}), do: "Key #{token_id}"
  defp marked({:key, token_id, agent}), do: said(agent, :key) <> " (key #{token_id})"
  defp marked({:item, _id, nil}), do: "an item"
  defp marked({:item, _id, title}), do: said(title, :item)
  defp marked({:room, _slug, name}), do: said(name, :room)
  defp marked({:agent, name}), do: said(name, :agent)
  defp marked({:quote, text}), do: said(text, :quote)

  defp said(text, what), do: DirectoryMD.inline(text, Map.fetch!(@limits, what))

  # A sentence that opens on an item no longer there opens "An item".
  defp capitalized("an item" <> rest), do: "An item" <> rest
  defp capitalized(sentence), do: sentence
end
