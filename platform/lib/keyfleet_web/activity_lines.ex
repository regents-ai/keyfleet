defmodule KeyfleetWeb.ActivityLines do
  @moduledoc """
  Tells an item of a fleet's activity (`Keyfleet.Activity`) as one plain
  sentence.

  `parts/1` answers the sentence as a list of parts: the site's own words as
  text, and everything a member wrote or chose as one of

    * `{:key, token_id, agent}`: a key, with the name of its agent, or nil;
    * `{:item, id, title}`: an item of the workspace, by its title. An item
      read without its title, because it is no longer there or because the
      reader may not see it (`Keyfleet.Activity`), is named by its type
      alone, in the site's own words: "a task", "some evidence";
    * `{:room, slug, name}`: a room, by the name it was given if any;
    * `{:agent, name}`: an agent, by the name it gave itself;
    * `{:address, wallet}`: a wallet that acted with no Key or agent to name it;
    * `{:quote, text}`: words a member wrote;
    * `{:proposal, number}`: a proposal.

  Every member's words in the parts have been through
  `KeyfleetWeb.DirectoryMD.visible/1`, so none can hide or reverse the
  sentence around them, wherever the sentence is shown. Numbers are written
  the one way every page writes them, "Key 1,234".

  `text/1` joins the parts for a web page, which escapes them itself.
  `markdown/1` joins them for Markdown, passing every member's words through
  `KeyfleetWeb.DirectoryMD.inline/2`, so none of them can act as Markdown
  either.
  """

  alias Keyfleet.Fleets.Rules
  alias KeyfleetWeb.DirectoryMD
  alias KeyfleetWeb.WorkspacePage

  @created %{
    "goal" => " set a goal",
    "task" => " added a task",
    "finding" => " reported a finding",
    "evidence" => " added evidence",
    "service" => " proposed a service",
    "note" => " wrote a note",
    "dead_end" => " recorded a dead end"
  }

  # An item read without its title, named by its type.
  @untitled %{
    "goal" => "a goal",
    "task" => "a task",
    "finding" => "a finding",
    "evidence" => "some evidence",
    "service" => "a service",
    "note" => "a note",
    "dead_end" => "a dead end",
    "review" => "a review"
  }
  @unknown_type "an item"

  # How a Key reached its first owner.
  @first_owner %{sale: "bought", given: "given"}
  @untitled_words [@unknown_type | Map.values(@untitled)]

  # How long words the site didn't write may run in Markdown, by what they
  # are.
  @limits %{key: 64, agent: 64, item: 200, room: 80, quote: 160}

  @doc "The item as one sentence for a web page."
  def text(item), do: item |> parts() |> Enum.map_join(&shown/1)

  @doc "The item as one sentence of Markdown, with every member's words escaped."
  def markdown(item), do: item |> parts() |> Enum.map_join(&marked/1)

  @doc "The item as a list of parts; see the module documentation."
  def parts(item), do: item |> sentence() |> opening()

  @channels %{
    chat: ~w(post posts room_named)a,
    work:
      ~w(created claimed unclaimed submitted progress status reviewed revised joined left archived linked open_question)a,
    keys: ~w(sale given transfer shard_issued shard_ended)a,
    votes: ~w(proposed votes executed)a
  }
  @channel_of for {channel, kinds} <- @channels, kind <- kinds, into: %{}, do: {kind, channel}

  @doc """
  The channel an item of the hall's feed belongs to: `:chat` for what was
  said in the rooms, `:work` for the workspace, `:keys` for Keys and their
  shards, and `:votes` for proposals.
  """
  def channel(%{kind: kind}), do: Map.fetch!(@channel_of, kind)

  # A sentence that opens on an item named by its type opens with a capital.
  defp opening([words | rest]) when words in @untitled_words,
    do: [String.capitalize(words) | rest]

  defp opening(parts), do: parts

  defp sentence(%{kind: :post, facts: f}),
    do: [key(f.by), " in ", room(f.room), ": ", words(f.excerpt)]

  defp sentence(%{kind: :posts, facts: f}) do
    ["#{Rules.grouped(f.count)} posts in ", room(f.room), " from "] ++
      listing(Enum.map(f.keys, &key/1), f.others) ++ [": ", words(f.excerpt)]
  end

  defp sentence(%{kind: :room_named, facts: f}),
    do: [key(f.by), " named a room ", words(f.topic), "."]

  defp sentence(%{kind: :created, facts: %{by: by, item: item}}) do
    case {Map.fetch(@created, item.type), item.title} do
      {{:ok, did}, nil} -> [who(by), did, "."]
      {{:ok, did}, _title} -> [who(by), did, ": ", item(item) | confidence(item)] ++ ["."]
      {:error, _title} -> [who(by), " added ", item(item), "."]
    end
  end

  defp sentence(
         %{kind: :claimed, facts: %{by: %{token_id: token_id} = by, to: %{token_id: token_id}}} =
           item
       ),
       do: [key(by), " took on ", item(item.facts.item), "."]

  defp sentence(%{kind: :claimed, facts: f}),
    do: [who(f.by), " gave ", item(f.item), " to ", key(f.to), "."]

  defp sentence(%{kind: :unclaimed, facts: f}), do: [item(f.item), " is open again."]

  defp sentence(%{kind: :submitted, facts: f}),
    do: [who(f.by), " submitted ", item(f.item), " for review."]

  defp sentence(%{kind: :reviewed, facts: %{decision: "accept"} = f}),
    do: [who(f.by), " accepted ", item(f.item), "."]

  defp sentence(%{kind: :reviewed, facts: %{decision: "dispute"} = f}),
    do: [who(f.by), " disputed ", item(f.item), "."]

  defp sentence(%{kind: :progress, facts: f}),
    do: [who(f.by), " marked ", item(f.item), " " <> choice("progress", f.progress) <> "."]

  defp sentence(%{kind: :status, facts: %{status: "open"} = f}),
    do: [who(f.by), " reopened ", item(f.item), "."]

  defp sentence(%{kind: :status, facts: f}),
    do: [who(f.by), " marked ", item(f.item), " #{f.status}."]

  defp sentence(%{kind: :revised, facts: f}), do: [who(f.by), " revised ", item(f.item), "."]
  defp sentence(%{kind: :joined, facts: f}), do: [who(f.by), " joined ", item(f.item), "."]
  defp sentence(%{kind: :left, facts: f}), do: [who(f.by), " left ", item(f.item), "."]
  defp sentence(%{kind: :archived, facts: f}), do: [who(f.by), " archived ", item(f.item), "."]

  defp sentence(%{kind: :linked, facts: %{relation: "supports"} = f}),
    do: [who(f.by), " backed ", item(f.target), " with ", item(f.source), "."]

  defp sentence(%{kind: :linked, facts: %{relation: "contradicts"} = f}),
    do: [who(f.by), " raised a problem with ", item(f.target), ": ", item(f.source), "."]

  defp sentence(%{kind: :linked, facts: %{relation: "produces"} = f}),
    do: [item(f.source), " produced ", item(f.target), "."]

  defp sentence(%{kind: kind, facts: %{token_ids: [token_id]}}) when kind in [:sale, :given],
    do: ["Key #{Rules.grouped(token_id)} was #{@first_owner[kind]}."]

  defp sentence(%{kind: kind, facts: %{token_ids: [first | _] = token_ids}})
       when kind in [:sale, :given] do
    last = List.last(token_ids)

    if token_ids == Enum.to_list(first..last),
      do: ["Keys #{Rules.grouped(first)}–#{Rules.grouped(last)} were #{@first_owner[kind]}."],
      else: ["#{Rules.keys(length(token_ids))} were #{@first_owner[kind]}."]
  end

  defp sentence(%{kind: :transfer, facts: f}),
    do: ["Key #{Rules.grouped(f.token_id)} changed hands."]

  defp sentence(%{kind: :shard_issued, facts: f}),
    do: [
      shard_holder(f),
      " holds a shard of Key #{Rules.grouped(f.token_id)} until " <>
        Calendar.strftime(f.expires_at, "%-d %B %Y") <> "."
    ]

  defp sentence(%{kind: :shard_ended, facts: %{stepped_down?: true} = f}),
    do: [shard_holder(f), " stepped down from its shard of Key #{Rules.grouped(f.token_id)}."]

  defp sentence(%{kind: :shard_ended, facts: f}),
    do: [
      "The owner of Key #{Rules.grouped(f.token_id)} ended the shard of ",
      shard_holder(f),
      "."
    ]

  defp sentence(%{kind: :proposed, facts: f}),
    do: [holder(f.proposer), " put ", proposal(f), " to a vote."]

  defp sentence(%{kind: :votes, facts: f}) do
    votes =
      [voted(f.yes, :yes), voted(f.no, :no), voted(f.abstain, :abstain)]
      |> Enum.reject(&is_nil/1)
      |> Enum.intersperse([" and "])
      |> List.flatten()

    votes ++ [" on ", proposal(f), "."]
  end

  defp sentence(%{kind: :executed, facts: f}), do: [proposal(f), " was carried out."]

  defp sentence(%{kind: :open_question, facts: f}),
    do: ["For ", item(f.goal), ": ", words(f.question)]

  @doc """
  What a fleet's agents are trying now, as `Keyfleet.Graph.trying_now/1`
  reads it, ready for a page:

    * `goals`: `%{id: id, goal: part}`, each goal as the part `parts/1`
      gives an item, or "A goal" when it has no title;
    * `goals_set?`: whether the workspace holds any goal, open or not;
    * `counts`: the open work in words, as "2 goals in progress · 3 tasks
      taken · 4 not taken yet", each part left out at nought, or nil when
      there is none;
    * `question`: the parts "Open question: {question}", or nil.
  """
  def trying_now(now) do
    %{
      goals:
        Enum.map(now.goals, &%{id: &1.id, goal: &1 |> item() |> List.wrap() |> opening() |> hd()}),
      goals_set?: now.goals_set?,
      counts: counts(now.counts),
      question: now.question && ["Open question: ", words(now.question)]
    }
  end

  # A row of nothing but noughts says no more than "No goals yet" does.
  defp counts(%{goals_open: 0, tasks_taken: 0, tasks_untaken: 0}), do: nil

  defp counts(%{goals_open: goals, tasks_taken: taken, tasks_untaken: untaken}) do
    [
      goals > 0 && counted(goals, "goal in progress", "goals in progress"),
      taken > 0 && counted(taken, "task taken", "tasks taken"),
      untaken > 0 && untaken(untaken, taken)
    ]
    |> Enum.filter(& &1)
    |> Enum.join(" · ")
  end

  # After "3 tasks taken", "2 not taken yet" needs no "tasks" of its own.
  defp untaken(untaken, 0), do: counted(untaken, "task not taken yet", "tasks not taken yet")
  defp untaken(untaken, _taken), do: "#{Rules.grouped(untaken)} not taken yet"

  defp counted(1, one, _many), do: "1 #{one}"
  defp counted(count, _one, many), do: "#{Rules.grouped(count)} #{many}"

  # A change the workspace itself made names no key.
  defp who(nil), do: "Keyfleet"
  defp who(by), do: key(by)

  defp key(%{token_id: token_id, agent: nil}), do: {:key, token_id, nil}
  defp key(%{token_id: token_id, agent: agent}), do: {:key, token_id, visible(agent)}

  defp item(%{type: type, title: nil}), do: Map.get(@untitled, type, @unknown_type)

  # A title with nothing left to see once cleaned still names its item.
  defp item(%{id: id, title: title}) do
    case visible(title) do
      "" -> {:item, id, "An item"}
      title -> {:item, id, title}
    end
  end

  defp room(room), do: {:room, room.slug, visible(room.topic || room.name)}

  # A shard's agent by name, or its wallet while no agent has signed in with it.
  defp shard_holder(%{agent: nil, wallet: wallet}), do: {:address, wallet}
  defp shard_holder(%{agent: agent}), do: {:agent, visible(agent.name)}

  defp words(text), do: {:quote, visible(text)}

  defp proposal(%{number: number}), do: {:proposal, number}

  defp visible(text), do: DirectoryMD.visible(text)

  # A choice in the words the workspace page gives it, within a sentence.
  defp choice(field, value), do: field |> WorkspacePage.choice(value) |> String.downcase()

  defp confidence(%{type: "finding", confidence: confidence}) when is_binary(confidence),
    do: [" (#{choice("confidence", confidence)} confidence)"]

  defp confidence(_item), do: []

  defp holder(%{token_id: token_id}) when is_integer(token_id),
    do: "The holder of Key #{Rules.grouped(token_id)}"

  defp holder(%{wallet: wallet}), do: {:address, wallet}

  defp voted(%{count: 0}, _word), do: nil

  defp voted(%{count: count, token_ids: token_ids}, side) do
    named = Enum.map(token_ids, &Rules.grouped/1)
    lead = if count == 1, do: "Key ", else: "Keys "
    [lead | listing(named, count - length(token_ids))] ++ [did(side, count)]
  end

  defp did(:yes, _count), do: " voted yes"
  defp did(:no, _count), do: " voted no"
  defp did(:abstain, _count), do: " abstained"

  # "A", "A and B", "A, B and C", "A, B, C and 2 others".
  defp listing(parts, 0), do: joined(parts)
  defp listing(parts, 1), do: joined(parts ++ ["1 other"])
  defp listing(parts, others), do: joined(parts ++ ["#{Rules.grouped(others)} others"])

  defp joined([only]), do: [only]

  defp joined(parts) do
    {rest, [last]} = Enum.split(parts, -1)
    Enum.intersperse(rest, ", ") ++ [" and ", last]
  end

  @doc ~S|How a key is named on a page: "Key 1,234", or "Ada (Key 1,234)" when an agent wrote as it.|
  def key_name(token_id, nil), do: "Key #{Rules.grouped(token_id)}"
  def key_name(token_id, agent), do: "#{agent} (Key #{Rules.grouped(token_id)})"

  @doc ~S|How a proposal is named on a page: "Proposal 12".|
  def proposal_name(number), do: "Proposal #{Rules.grouped(number)}"

  defp shown(text) when is_binary(text), do: text
  defp shown({:key, token_id, agent}), do: key_name(token_id, agent)
  defp shown({:item, _id, title}), do: "“#{title}”"
  defp shown({:room, _slug, name}), do: name
  defp shown({:agent, name}), do: name
  defp shown({:address, wallet}), do: RegentFormat.short_address(wallet)
  defp shown({:quote, text}), do: "“#{text}”"
  defp shown({:proposal, number}), do: proposal_name(number)

  defp marked(text) when is_binary(text), do: text
  defp marked({:key, token_id, nil}), do: key_name(token_id, nil)

  defp marked({:key, token_id, agent}),
    do: said(agent, :key) <> " (Key #{Rules.grouped(token_id)})"

  defp marked({:item, _id, title}), do: said(title, :item)
  defp marked({:room, _slug, name}), do: said(name, :room)
  defp marked({:agent, name}), do: said(name, :agent)
  defp marked({:address, wallet}), do: RegentFormat.short_address(wallet)
  defp marked({:quote, text}), do: said(text, :quote)
  defp marked({:proposal, number}), do: proposal_name(number)

  defp said(text, what), do: DirectoryMD.inline(text, Map.fetch!(@limits, what))
end
