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
    * `{:quote, text}`: words a member wrote, or a launch's name;
    * `{:proposal, number}`: a proposal;
    * `{:amount, text, token}`: an amount paid in a token other than the
      fleet's USDC, as `KeyfleetWeb.ProposalsPage.amount/3` words it with
      the symbol the token chose, and the token's address.

  Every member's words and every token's symbol in the parts have been through
  `KeyfleetWeb.DirectoryMD.visible/1`, so none can hide or reverse the
  sentence around them, wherever the sentence is shown. Numbers are written
  the one way every page writes them, "Key 1,234".

  `text/1` joins the parts for a web page, which escapes them itself.
  `markdown/1` joins them for Markdown, passing every member's words and
  every amount in a token's own symbol through
  `KeyfleetWeb.DirectoryMD.inline/2`, so none of them can act as Markdown
  either. Both quote an amount in a token's own symbol, so the symbol can't
  pass for the site's words, such as whom the fleet paid.
  """

  alias Keyfleet.Fleets.Rules
  alias Keyfleet.Graph
  alias KeyfleetWeb.DirectoryMD
  alias KeyfleetWeb.FleetLive
  alias KeyfleetWeb.ProposalsPage
  alias KeyfleetWeb.WorkspacePage

  @created %{
    "goal" => " set a goal: ",
    "task" => " added a task: ",
    "finding" => " reported a finding: ",
    "evidence" => " added evidence: ",
    "service" => " proposed a service: ",
    "launch_card" => " started a launch plan: ",
    "note" => " wrote a note: "
  }

  # How long words the site didn't write may run in Markdown, by what they
  # are. An amount fits whole: any uint256 at up to 255 decimals, and its
  # token's symbol.
  @limits %{key: 64, agent: 64, item: 200, room: 80, quote: 160, amount: 400}

  @doc "The item as one sentence for a web page."
  def text(item), do: item |> parts() |> Enum.map_join(&shown/1) |> capitalized()

  @doc "The item as one sentence of Markdown, with every member's words escaped."
  def markdown(item), do: item |> parts() |> Enum.map_join(&marked/1) |> capitalized()

  @doc "The item as a list of parts; see the module documentation."
  def parts(%{kind: :post, facts: f}),
    do: [key(f.by), " in ", room(f.room), ": ", words(f.excerpt)]

  def parts(%{kind: :posts, facts: f}) do
    ["#{Rules.grouped(f.count)} posts in ", room(f.room), " from "] ++
      listing(Enum.map(f.keys, &key/1), f.others) ++ [": ", words(f.excerpt)]
  end

  def parts(%{kind: :room_named, facts: f}),
    do: [key(f.by), " named a room ", words(f.topic), "."]

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
    do: [who(f.by), " marked ", item(f.item), " " <> choice("progress", f.progress) <> "."]

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

  def parts(%{kind: :sale, facts: %{token_ids: [token_id]}}),
    do: ["Key #{Rules.grouped(token_id)} was bought."]

  def parts(%{kind: :sale, facts: %{token_ids: [first | _] = token_ids}}) do
    last = List.last(token_ids)

    if token_ids == Enum.to_list(first..last),
      do: ["Keys #{Rules.grouped(first)}–#{Rules.grouped(last)} were bought."],
      else: ["#{Rules.keys(length(token_ids))} were bought."]
  end

  def parts(%{kind: :transfer, facts: f}),
    do: ["Key #{Rules.grouped(f.token_id)} changed hands."]

  def parts(%{kind: :agent_started, facts: f}),
    do: [agent(f.agent), " started running key #{Rules.grouped(f.token_id)}."]

  def parts(%{kind: :agent_stopped, facts: f}) do
    stopped =
      if f.ended_reason == :stepped_down,
        do: " stepped down from key #{Rules.grouped(f.token_id)}",
        else: " stopped running key #{Rules.grouped(f.token_id)}"

    moved_on =
      case f.now_runs do
        %{token_id: token_id, fleet_name: fleet_name} ->
          ", and now runs key #{Rules.grouped(token_id)} in #{fleet_name}."

        nil ->
          "."
      end

    [agent(f.agent), stopped, moved_on]
  end

  def parts(%{kind: :proposed, facts: f}),
    do: [holder(f.proposer), " put ", proposal(f), " to a vote" | proposal_gist(f)]

  def parts(%{kind: :votes, facts: f}) do
    votes =
      [voted(f.yes, :yes), voted(f.no, :no), voted(f.withdrawn, :withdrawn)]
      |> Enum.reject(&is_nil/1)
      |> Enum.intersperse([" and "])
      |> List.flatten()

    votes ++ [" on ", proposal(f), "."]
  end

  def parts(%{kind: :executed, facts: %{kind: :decision} = f}),
    do: [proposal(f), " was recorded as decided."]

  def parts(%{kind: :executed, facts: %{kind: :pay} = f}),
    do: ["The fleet paid " | paid(f.payment)] ++ [" (", proposal(f), ")."]

  def parts(%{kind: :executed, facts: %{kind: :autolaunch, launch: %{} = launch} = f}),
    do: ["The fleet launched ", launch(launch), " (", proposal(f), ")."]

  def parts(%{kind: :executed, facts: %{kind: :autolaunch} = f}),
    do: ["The fleet launched its token (", proposal(f), ")."]

  def parts(%{kind: :open_question, facts: f}),
    do: ["For ", item(f.goal), ": ", words(f.question)]

  @doc """
  What a fleet's agents are trying now, as `Keyfleet.Graph.trying_now/1`
  reads it, ready for a page; `agents` names the agent running each key, by
  its number. Items and keys are parts, as `parts/1` gives them:

    * `goals`: `%{id: id, goal: item, tally: text, tasks: [task]}`, where
      `tally` counts the tasks listed and those done, as "3 tasks · 1 done",
      or says "5 newest tasks" alone when the goal may have more than those
      listed;
    * `taken`: `[task]`, the tasks in progress that a key has taken;
    * `problems`: `%{id: link_id, target: item, source: item}`, the item a
      problem was raised with and the one raising it, for as long as the
      link is there;
    * `findings`: `%{id: id, finding: item, confidence: text}`;
    * `question`: the parts "Open question: {question}", or nil.

  A task is `%{id: id, task: item, key: key | nil, progress: text}`, with
  its progress in words, as "In progress".
  """
  def trying_now(now, agents) do
    %{
      goals: Enum.map(now.goals, &goal(&1, agents)),
      taken: Enum.map(now.taken, &task(&1, agents)),
      problems:
        for %{relation: link, source: source, target: target} <- now.problems do
          %{id: link.id, target: item(target), source: item(source)}
        end,
      findings:
        for finding <- now.findings do
          confidence = WorkspacePage.choice("confidence", finding.card["confidence"])
          %{id: finding.id, finding: item(finding), confidence: "#{confidence} confidence"}
        end,
      question: now.question && ["Open question: ", words(now.question)]
    }
  end

  defp goal(%{goal: goal, tasks: tasks}, agents) do
    %{
      id: goal.id,
      goal: item(goal),
      tally: tally(tasks),
      tasks: Enum.map(tasks, &task(&1, agents))
    }
  end

  # A goal's task may be one no key has taken.
  defp task(%{task: task, assignee_key: token_id}, agents) do
    %{
      id: task.id,
      task: item(task),
      key: token_id && key(%{token_id: token_id, agent: agents[token_id]}),
      progress: WorkspacePage.choice("progress", task.card["progress"])
    }
  end

  # A goal listing as many tasks as are ever listed may have more, so how
  # many of all its tasks are done isn't known: none is counted.
  defp tally([]), do: "No tasks yet"

  defp tally(tasks) do
    done = Enum.count(tasks, &(&1.task.card["progress"] == "done"))

    case length(tasks) do
      1 ->
        "1 task · #{done} done"

      count ->
        if count == Graph.tasks_per_goal(),
          do: "#{count} newest tasks",
          else: "#{count} tasks · #{done} done"
    end
  end

  # A change the workspace itself made names no key.
  defp who(nil), do: "Keyfleet"
  defp who(by), do: key(by)

  defp key(%{token_id: token_id, agent: nil}), do: {:key, token_id, nil}
  defp key(%{token_id: token_id, agent: agent}), do: {:key, token_id, visible(agent)}

  # A title with nothing left to see once cleaned still names its item.
  defp item(%{id: id, title: nil}), do: {:item, id, nil}

  defp item(%{id: id, title: title}) do
    case visible(title) do
      "" -> {:item, id, "An item"}
      title -> {:item, id, title}
    end
  end

  defp room(room), do: {:room, room.slug, visible(room.topic || room.name)}

  defp agent(%{name: name}), do: {:agent, visible(name)}

  defp words(text), do: {:quote, visible(text)}

  defp proposal(%{number: number}), do: {:proposal, number}

  defp visible(text), do: DirectoryMD.visible(text)

  # A choice in the words the workspace page gives it, within a sentence.
  defp choice(field, value), do: field |> WorkspacePage.choice(value) |> String.downcase()

  defp confidence(%{type: "finding", confidence: confidence}) when is_binary(confidence),
    do: [" (#{choice("confidence", confidence)} confidence)"]

  defp confidence(_item), do: []

  defp holder(%{token_id: token_id}) when is_integer(token_id),
    do: "The holder of key #{Rules.grouped(token_id)}"

  defp holder(%{wallet: wallet}), do: FleetLive.short_wallet(wallet)

  defp proposal_gist(%{kind: :autolaunch, launch: %{} = launch}),
    do: [" to launch ", launch(launch), "."]

  defp proposal_gist(%{kind: :pay, payment: payment} = facts),
    do: [" to pay " | paid(payment)] ++ gist(facts)

  defp proposal_gist(facts), do: gist(facts)

  defp gist(%{gist: gist}) when is_binary(gist), do: [": ", words(gist)]
  defp gist(_facts), do: ["."]

  # "12.5 USDC to 0x12ab…cd34".
  defp paid(payment) do
    amount = ProposalsPage.amount(payment.amount, payment.asset, payment.assets)
    [amount(amount), " to #{FleetLive.short_wallet(payment.recipient)}"]
  end

  # The fleet's USDC, and a token that hasn't said its symbol, are named in
  # the site's words; any other token by the symbol it chose.
  defp amount(%{text: text, token: nil}), do: visible(text)

  defp amount(%{text: text, token: token, symbol?: false}),
    do: "#{text} #{FleetLive.short_wallet(token)}"

  defp amount(%{text: text, token: token, symbol?: true}), do: {:amount, visible(text), token}

  defp launch(%{name: name, symbol: symbol}), do: words("#{name} (#{symbol})")

  defp voted(%{count: 0}, _word), do: nil

  defp voted(%{count: count, token_ids: token_ids}, side) do
    named = Enum.map(token_ids, &Rules.grouped/1)
    lead = if count == 1, do: "Key ", else: "Keys "
    [lead | listing(named, count - length(token_ids))] ++ [did(side, count)]
  end

  defp did(:yes, _count), do: " voted yes"
  defp did(:no, _count), do: " voted no"
  defp did(:withdrawn, 1), do: " withdrew its vote"
  defp did(:withdrawn, _count), do: " withdrew their votes"

  # "A", "A and B", "A, B and C", "A, B, C and 2 others".
  defp listing(parts, 0), do: joined(parts)
  defp listing(parts, 1), do: joined(parts ++ ["1 other"])
  defp listing(parts, others), do: joined(parts ++ ["#{Rules.grouped(others)} others"])

  defp joined([only]), do: [only]

  defp joined(parts) do
    {rest, [last]} = Enum.split(parts, -1)
    Enum.intersperse(rest, ", ") ++ [" and ", last]
  end

  @doc ~S|How a key is named on a page: "Key 1,234", or "Ada (key 1,234)" when an agent runs it.|
  def key_name(token_id, nil), do: "Key #{Rules.grouped(token_id)}"
  def key_name(token_id, agent), do: "#{agent} (key #{Rules.grouped(token_id)})"

  @doc ~S|How a proposal is named on a page: "Proposal 12".|
  def proposal_name(number), do: "Proposal #{Rules.grouped(number)}"

  @doc ~S|How an amount in a token's own symbol is named on a page: "“3 FOO” 0xabcd…ef01".|
  def amount_name(text, token), do: "“#{text}” #{FleetLive.short_wallet(token)}"

  defp shown(text) when is_binary(text), do: text
  defp shown({:key, token_id, agent}), do: key_name(token_id, agent)
  defp shown({:item, _id, nil}), do: "an item"
  defp shown({:item, _id, title}), do: "“#{title}”"
  defp shown({:room, _slug, name}), do: name
  defp shown({:agent, name}), do: name
  defp shown({:quote, text}), do: "“#{text}”"
  defp shown({:proposal, number}), do: proposal_name(number)
  defp shown({:amount, text, token}), do: amount_name(text, token)

  defp marked(text) when is_binary(text), do: text
  defp marked({:key, token_id, nil}), do: key_name(token_id, nil)

  defp marked({:key, token_id, agent}),
    do: said(agent, :key) <> " (key #{Rules.grouped(token_id)})"

  defp marked({:item, _id, nil}), do: "an item"
  defp marked({:item, _id, title}), do: said(title, :item)
  defp marked({:room, _slug, name}), do: said(name, :room)
  defp marked({:agent, name}), do: said(name, :agent)
  defp marked({:quote, text}), do: said(text, :quote)
  defp marked({:proposal, number}), do: proposal_name(number)

  defp marked({:amount, text, token}),
    do: said(text, :amount) <> " " <> FleetLive.short_wallet(token)

  defp said(text, what), do: DirectoryMD.inline(text, Map.fetch!(@limits, what))

  # A sentence that opens on an item no longer there opens "An item".
  defp capitalized("an item" <> rest), do: "An item" <> rest
  defp capitalized(sentence), do: sentence
end
