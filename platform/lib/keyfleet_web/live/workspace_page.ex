defmodule KeyfleetWeb.WorkspacePage do
  @moduledoc """
  What a fleet's workspace pages show, read from the workspace's read tables
  alone, never from the fleet's writer.

  `board/3` is the fleet's items a page at a time, the most recently changed
  first, beside its latest changes and the changes sent to its code
  (`Keyfleet.Code`); `item/4` is one item with its fields, its
  links a page at a time and its history a page at a time. Each answers
  `seen`, the log and the place in it the read tables had reached when the
  page was read. Every change is told as one plain line: a list of parts, each a piece of text, a key
  (`{:key, token_id, agent}`, with the name of the agent that wrote as it, or
  nil) or an item (`{:item, id, title}`, with a `nil` title when the item is
  not in the workspace). Who added an item is a key told the same way, so two
  agents writing as one person's key are told apart.

  `commit/4` is one commit in the fleet's code, at the address a workspace
  cites it by (`commit_url/2`): who sent it, and the evidence that cites it
  with the tasks that produced that evidence.

  Only the fleet's members read its workspace
  (`Keyfleet.Graph.Checks.KeyReader`) and its code: for anyone else every page
  answers `members_only?: true`. The board then shows the fleet's outline,
  each goal and task by title, standing and the public summary its members
  wrote, beside its latest workspace changes told as the fleet's feed tells
  them to anyone (`Keyfleet.Activity.work/2`); nothing else members write.
  An item's page shows that item's own outline entry first, when it is a
  goal or task in the outline.

  A page name that is not one the tables can answer, such as an unknown type
  or a damaged page position, is a page that doesn't exist.
  """

  alias Keyfleet.{Activity, Agents, Code, Fleets, Notebooks}
  alias Keyfleet.Graph
  alias Keyfleet.Rooms
  alias KeyfleetWeb.ActivityLines
  alias KeyfleetWeb.DirectoryMD
  alias KeyfleetWeb.Endpoint
  alias KeyfleetWeb.NotFoundError
  alias KeyfleetWeb.RoomsLive

  @types ~w(goal task finding evidence service note dead_end review)

  @type_names %{
    "goal" => {"goal", "Goals"},
    "task" => {"task", "Tasks"},
    "finding" => {"finding", "Findings"},
    "evidence" => {"evidence", "Evidence"},
    "service" => {"service", "Services"},
    "note" => {"note", "Notes"},
    "dead_end" => {"dead end", "Dead ends"},
    "review" => {"review", "Reviews"}
  }

  # Each type's fields in the order they are shown, with their names; any
  # other field is shown after them under its own name.
  @fields %{
    "goal" => [
      {"outcome", "Outcome"},
      {"status", "Status"},
      {"public_summary", "Public summary"},
      {"success_criteria", "Success criteria"},
      {"open_questions", "Open questions"}
    ],
    "task" => [
      {"progress", "Progress"},
      {"assignee_key", "Taken by"},
      {"deliverable", "Deliverable"},
      {"next_step", "Next step"},
      {"result_ref", "Result"},
      {"public_summary", "Public summary"}
    ],
    "finding" => [
      {"statement", "Statement"},
      {"confidence", "Confidence"},
      {"uncertainty", "Uncertainty"}
    ],
    "evidence" => [
      {"source_uri", "Source"},
      {"excerpt", "Excerpt"},
      {"how_obtained", "How it was found"},
      {"digest", "Document code"}
    ],
    "service" => [
      {"customer", "Customer"},
      {"problem", "Problem"},
      {"deliverable", "Deliverable"},
      {"price_proposal", "Proposed price"},
      {"payment_asset", "Paid in"},
      {"implementation_refs", "Work so far"}
    ],
    "note" => [{"body", "Note"}],
    "dead_end" => [
      {"what_was_tried", "What was tried"},
      {"why_it_failed", "Why it didn’t work"}
    ],
    "review" => [
      {"decision", "Decision"},
      {"rationale", "Reasons"},
      {"conflicts_of_interest", "Conflicts of interest"}
    ]
  }

  @choices %{
    "progress" => %{
      "todo" => "To do",
      "doing" => "In progress",
      "blocked" => "Blocked",
      "done" => "Submitted"
    },
    "review" => %{
      "awaiting_review" => "Awaiting review",
      "accepted" => "Accepted",
      "disputed" => "Disputed"
    },
    "decision" => %{"accept" => "Accepted", "dispute" => "Disputed"},
    "status" => %{"open" => "Open", "achieved" => "Achieved", "dropped" => "Dropped"},
    "confidence" => %{"low" => "Low", "medium" => "Medium", "high" => "High"},
    "payment_asset" => %{
      "USDC" => "USDC",
      "REGENT" => "REGENT",
      "FLEET_TOKEN" => "the fleet’s own token"
    }
  }

  # Where a submitted task's review can stand.
  @reviews Map.keys(@choices["review"])

  # What one item is to another, read from the link's source to its target.
  @relations %{
    "supports" => "supports",
    "contradicts" => "contradicts",
    "depends_on" => "depends on",
    "implements" => "delivers on",
    "produces" => "produces",
    "references" => "mentions",
    "reviews" => "reviews"
  }

  # How every time on a workspace page is written.
  @at "%-d %B %Y at %H:%M UTC"

  # How many goals and tasks a fleet's outline shows anyone.
  @outlined %{"goal" => 12, "task" => 24}

  # Only these kinds of address are ever made into links.
  @link_schemes ["https://", "ipfs://", "ar://", "git+https://"]
  @room_slug ~r/\A[a-z0-9][a-z0-9-]{0,62}\z/
  # One saved page of a notebook version or background run, after the
  # notebooks' `/results/`: notebook id, version or run id, and when the page
  # was saved in milliseconds since 1970.
  @saved_result ~r/\Anb-[a-z0-9]{16}\/(ver_[0-9A-Z]{26}|run_[0-9A-HJKMNP-TV-Z]{26})\/[1-9][0-9]{0,15}\z/
  @level ~r/\Alevel:([1-9][0-9]{0,8})\z/

  @doc "The types of item a workspace holds."
  def types, do: @types

  @doc "The name of a type, and of several of it."
  def type_name(type), do: Map.get(@type_names, type, {"item", "Items"})

  @doc "The path of an item's page."
  def item_path(fleet_id, id, query \\ []),
    do:
      with_query(
        "#{Keyfleet.Fleets.path(fleet_id)}/workspace/#{URI.encode(id, &URI.char_unreserved?/1)}",
        query
      )

  @doc "The path of the fleet's workspace, showing `filter` from `position`."
  def board_path(fleet_id, filter, position \\ []) do
    query =
      Enum.reject(
        [type: filter.type, archived: if(filter.archived?, do: "shown")] ++ position,
        &is_nil(elem(&1, 1))
      )

    with_query("#{Keyfleet.Fleets.path(fleet_id)}/workspace", query)
  end

  @doc "The address a workspace cites one commit of the fleet's code by."
  def commit_url(fleet_id, hash), do: Endpoint.url() <> Code.commit_path(fleet_id, hash)

  defp with_query(path, []), do: path
  defp with_query(path, query), do: path <> "?" <> URI.encode_query(query)

  @doc "The fleet's items, a page of them, and its latest changes."
  def board(fleet_id, params, actor) do
    filter = filter!(params)
    opts = [actor: actor]

    with {:ok, fleet} <- fleet(fleet_id, opts),
         {:ok, page} <- cards_page(fleet, filter, params, opts),
         {:ready, cursor} <- ready(fleet, opts) do
      activity = Graph.latest_activity!(fleet_id, opts)
      titles = titles(fleet_id, Enum.flat_map(activity, &mentions/1), opts)

      agents =
        agent_names(
          Enum.map(page.results, &creator_wallet(&1.sys)) ++ Enum.map(activity, &actor_wallet/1)
        )

      notes =
        fleet_id
        |> Graph.workspace_cards!(%{type: "note"}, Keyword.put(opts, :page, limit: 24))
        |> Map.fetch!(:results)
        |> Map.new(&{&1.changed_seq, &1.card["gist"]})

      %{
        fleet_id: fleet_id,
        fleet_name: fleet.name,
        ready?: true,
        seen: seen(cursor),
        filter: filter,
        cards: Enum.map(page.results, &card(&1, fleet_id, agents)),
        first_page?: not paged?(params),
        first_page: board_path(fleet_id, filter),
        pages: page_links(page, params, &board_path(fleet_id, filter, &1)),
        activity: Enum.map(activity, &Map.put(line(&1, titles, agents), :note, notes[&1.seq])),
        code: %{
          clone_url: Code.clone_url(fleet_id),
          pushes: pushes(Code.recent_pushes!(fleet_id, opts), fleet_id)
        }
      }
    else
      {:missing, name} ->
        %{fleet_id: fleet_id, fleet_name: name, ready?: false, seen: nil, filter: filter}

      {:members_only, name} ->
        members_only(fleet_id, name, actor, nil)
    end
  end

  @doc "One item, a page of its links and a page of its history."
  def item(fleet_id, object_id, params, actor) do
    opts = [actor: actor]
    links_at = position!(params, "links")
    history_through = history_position!(params)

    with {:ok, fleet} <- fleet(fleet_id, opts),
         {:ok, object} <-
           members_read(fleet, Graph.read_object(fleet_id, object_id, [load: [:review]] ++ opts)),
         {:ready, cursor} <- ready(fleet, opts) do
      base = %{fleet_id: fleet_id, fleet_name: fleet.name, ready?: true, seen: seen(cursor)}

      case object do
        nil ->
          Map.put(base, :object, nil)

        object ->
          links =
            page!(
              Graph.object_links(fleet_id, object_id, page: links_at ++ [limit: 50], actor: actor)
            )

          {history, earlier} =
            fleet_id
            |> Graph.object_history(object_id, history_through, actor: actor)
            |> page!()
            |> Enum.split(50)

          others = Enum.map(links.results, &other_end(&1, object_id))
          titles = titles(fleet_id, others ++ Enum.flat_map(history, &mentions/1), opts)

          agents =
            agent_names(
              [creator_wallet(object.sys) | joined_wallets(object.sys)] ++
                Enum.map(history, &actor_wallet/1)
            )

          path = &item_path(fleet_id, object_id, item_query(params, &1, &2))

          Map.merge(base, %{
            object: detail(object, fleet_id, agents, opts),
            links: %{
              rows: Enum.map(links.results, &link_row(&1, object, titles)),
              more:
                if(links.more?,
                  do: path.("links", List.last(links.results).__metadata__.keyset)
                ),
              first: if(links_at != [], do: path.("links", nil))
            },
            history: %{
              lines: Enum.map(history, &line(&1, titles, agents)),
              more: if(earlier != [], do: path.("history", List.last(history).seq - 1)),
              first: if(history_through != %{}, do: path.("history", nil))
            }
          })
      end
    else
      {:missing, name} -> %{fleet_id: fleet_id, fleet_name: name, ready?: false, seen: nil}
      {:members_only, name} -> members_only(fleet_id, name, actor, object_id)
    end
  end

  defp members_only(fleet_id, name, actor, object_id) do
    %{
      fleet_id: fleet_id,
      fleet_name: name,
      members_only?: true,
      seen: nil,
      focus: focus(fleet_id, object_id),
      work:
        for item <- Activity.work(fleet_id, actor: actor) do
          %{id: item.id, at: Calendar.strftime(item.at, @at), parts: ActivityLines.parts(item)}
        end,
      outline:
        Map.new(@outlined, fn {type, limit} -> {type, outline(fleet_id, type, limit: limit)} end)
    }
  end

  # The goal or task an item's page names, as the outline shows it to anyone.
  defp focus(_fleet_id, nil), do: nil

  defp focus(fleet_id, object_id) do
    case String.split(object_id, "#", parts: 2) do
      [type, _number] when type in ["goal", "task"] ->
        fleet_id
        |> outline(type, filter: [id: object_id], limit: 1)
        |> List.first()
        |> then(&(&1 && Map.put(&1, :type_name, type |> type_name() |> elem(0))))

      _other ->
        nil
    end
  end

  defp outline(fleet_id, type, query) do
    for object <- Graph.outline!(fleet_id, type, query: query) do
      %{
        id: object.id,
        title: object.title,
        standing: standing(type, object.standing),
        summary: object.public_summary
      }
    end
  end

  defp standing("goal", status), do: choice("status", status)

  defp standing("task", review) when review in @reviews, do: choice("review", review)

  defp standing("task", progress), do: choice("progress", progress)

  @doc """
  One commit of the fleet's code, named by its repository and full hash:
  the pushes that left a branch or tag at it, and the evidence that cites it
  with the tasks that produced that evidence. An address naming another
  repository, or less than a full hash, is a page that doesn't exist.
  """
  def commit(fleet_id, repository, hash, actor) do
    if repository != fleet_id or not Code.full_hash?(hash), do: raise(NotFoundError)
    opts = [actor: actor]
    url = commit_url(fleet_id, hash)

    with {:ok, fleet} <- fleet(fleet_id, opts),
         {:ok, pushes} <- members_read(fleet, Code.pushes_of_commit(fleet_id, hash, opts)),
         {:ok, evidence} <- members_read(fleet, Graph.evidence_citing(fleet_id, url, opts)) do
      producers = producers(fleet_id, evidence, opts)
      titles = titles(fleet_id, producers |> Map.values() |> List.flatten(), opts)
      agents = agent_names(Enum.map(evidence, &creator_wallet(&1.sys)))

      %{
        fleet_id: fleet_id,
        fleet_name: fleet.name,
        hash: hash,
        url: url,
        clone_url: Code.clone_url(fleet_id),
        pushes: pushes(pushes, fleet_id),
        evidence:
          for object <- evidence do
            %{
              id: object.id,
              title: object.title,
              excerpt: object.card["gist"],
              archived?: archived?(object.sys),
              by: created_by(object.sys, agents),
              tasks: Enum.map(Map.get(producers, object.id, []), &item_part(&1, titles))
            }
          end
      }
    else
      {:missing, _name} ->
        raise NotFoundError

      {:members_only, name} ->
        %{fleet_id: fleet_id, fleet_name: name, hash: hash, members_only?: true}
    end
  end

  # The tasks that produced each piece of evidence, by the evidence's id.
  defp producers(_fleet_id, [], _opts), do: %{}

  defp producers(fleet_id, evidence, opts) do
    fleet_id
    |> Graph.producers_of!(Enum.map(evidence, & &1.id), opts)
    |> Enum.group_by(& &1.target, & &1.source)
  end

  # The first read of the workspace a page makes is the one that finds out
  # whether the reader is one of the fleet's members.
  defp members_read(_fleet, {:ok, result}), do: {:ok, result}
  defp members_read(fleet, {:error, %Ash.Error.Forbidden{}}), do: {:members_only, fleet.name}
  defp members_read(_fleet, {:error, %Ash.Error.Invalid{}}), do: raise(NotFoundError)
  defp members_read(_fleet, {:error, failure}), do: raise(failure)

  # An item page's links and history are paged apart: moving one keeps where
  # the other stands.
  defp item_query(params, name, position) do
    %{"links" => params["links"], "history" => params["history"]}
    |> Map.put(name, position)
    |> Enum.reject(&is_nil(elem(&1, 1)))
    |> Enum.sort()
  end

  defp fleet(fleet_id, opts) do
    case Fleets.get_fleet!(fleet_id, opts) do
      nil -> {:missing, nil}
      fleet -> {:ok, fleet}
    end
  end

  # A workspace is readable once its log has started being copied.
  defp ready(fleet, opts) do
    case Graph.get_cursor!(fleet.id, opts) do
      nil -> {:missing, fleet.name}
      cursor -> {:ready, cursor}
    end
  end

  defp seen(cursor), do: {cursor.run_id, cursor.applied_seq}

  defp filter!(params) do
    type =
      case params["type"] do
        nil -> nil
        type when type in @types -> type
        _unknown -> raise NotFoundError
      end

    archived? =
      case params["archived"] do
        nil -> false
        "shown" -> true
        _unknown -> raise NotFoundError
      end

    %{type: type, archived?: archived?}
  end

  defp cards_page(fleet, filter, params, opts) do
    read =
      Graph.workspace_cards(
        fleet.id,
        %{type: filter.type, include_archived?: filter.archived?},
        Keyword.put(opts, :page, card_position(params) ++ [limit: 24])
      )

    members_read(fleet, read)
  end

  defp card_position(%{"after" => keyset}) when is_binary(keyset), do: [after: keyset]
  defp card_position(%{"before" => keyset}) when is_binary(keyset), do: [before: keyset]
  defp card_position(params), do: if(paged?(params), do: raise(NotFoundError), else: [])

  defp paged?(params), do: Map.has_key?(params, "after") or Map.has_key?(params, "before")

  defp position!(params, name) do
    case params[name] do
      nil -> []
      keyset when is_binary(keyset) -> [after: keyset]
      _unknown -> raise NotFoundError
    end
  end

  # An item's history is paged by the place in the log it reads back from.
  defp history_position!(params) do
    case params["history"] do
      nil ->
        %{}

      through when is_binary(through) ->
        if String.match?(through, ~r/\A(0|[1-9][0-9]{0,18})\z/),
          do: %{through_seq: String.to_integer(through)},
          else: raise(NotFoundError)

      _unknown ->
        raise NotFoundError
    end
  end

  defp page!({:ok, page}), do: page
  defp page!({:error, %Ash.Error.Invalid{}}), do: raise(NotFoundError)
  defp page!({:error, failure}), do: raise(failure)

  # A page reached by going forward always has one before it, and one reached
  # by going back always has one after it.
  defp page_links(%Ash.Page.Keyset{results: []}, _params, _path),
    do: %{previous: nil, next: nil}

  defp page_links(%Ash.Page.Keyset{results: results, more?: more?}, params, path) do
    {previous?, next?} =
      case params do
        %{"after" => _keyset} -> {true, more?}
        %{"before" => _keyset} -> {more?, true}
        _first_page -> {false, more?}
      end

    %{
      previous: if(previous?, do: path.(before: hd(results).__metadata__.keyset)),
      next: if(next?, do: path.(after: List.last(results).__metadata__.keyset))
    }
  end

  defp titles(_fleet_id, [], _opts), do: %{}

  defp titles(fleet_id, ids, opts) do
    fleet_id
    |> Graph.object_titles!(Enum.uniq(ids), opts)
    |> Map.new(&{&1.id, &1})
  end

  defp card(object, fleet_id, agents) do
    %{
      id: object.id,
      type: object.type,
      title: object.title,
      archived?: archived?(object.sys),
      level: level(object.sys),
      by: created_by(object.sys, agents),
      changed_at: at(object.changed_at),
      facts:
        facts(object.type, Map.put(object.card, "review", object.review), fleet_id) ++
          joined_fact(object.sys),
      gist: object.card["gist"]
    }
  end

  defp facts("goal", card, _fleet_id),
    do: present([{"Status", choice("status", card["status"])}])

  defp facts("task", card, _fleet_id) do
    present([
      {"Progress", choice("progress", card["progress"])},
      {"Review", card["review"] && choice("review", card["review"])},
      {"Taken by", key_or(card["assignee_key"], "No one yet")}
    ])
  end

  defp facts("finding", card, _fleet_id),
    do: present([{"Confidence", choice("confidence", card["confidence"])}])

  defp facts("evidence", card, fleet_id),
    do: present([{"Source", source(card["source_uri"], fleet_id)}])

  defp facts("service", card, _fleet_id) do
    price =
      case {card["price_proposal"], card["payment_asset"]} do
        {nil, _asset} -> nil
        {price, nil} -> price
        {price, "FLEET_TOKEN"} -> "#{price} in the fleet’s own token"
        {price, asset} -> "#{price} #{asset}"
      end

    present([{"Customer", card["customer"]}, {"Proposed price", price}])
  end

  defp facts(_type, _card, _fleet_id), do: []

  defp present(facts), do: Enum.reject(facts, &is_nil(elem(&1, 1)))

  defp detail(object, fleet_id, agents, opts) do
    known = Map.get(@fields, object.type, [])
    shown = MapSet.new(["title", "discussion" | Enum.map(known, &elem(&1, 0))])

    others =
      object.data
      |> Map.keys()
      |> Enum.reject(&MapSet.member?(shown, &1))
      |> Enum.sort()
      |> Enum.map(&{&1, humanize(&1)})

    %{
      id: object.id,
      type: object.type,
      title: object.data["title"],
      archived?: archived?(object.sys),
      level: level(object.sys),
      by: created_by(object.sys, agents),
      version: object.version,
      changed_at: at(object.changed_at),
      fields:
        receipt(object) ++
          Enum.flat_map(known ++ others, fn {field, label} ->
            case field_value(field, object.data[field], fleet_id) do
              nil -> []
              shown -> [{label, shown}]
            end
          end) ++ joined_field(object.sys, agents),
      discussion: discussion(object.data["discussion"], fleet_id, opts)
    }
  end

  # Where a submitted task's review stands, and what a review judged: the
  # task's version and who submitted it.
  defp receipt(%{type: "task", review: review}) when is_binary(review),
    do: [{"Review", choice("review", review)}]

  defp receipt(%{type: "review", sys: %{"review" => review}}) do
    [
      {"Version reviewed", Integer.to_string(review["task_version"])},
      {"Submitted by", {:key, review["submitted_by"]["key"]["token_id"], nil}}
    ]
  end

  defp receipt(_object), do: []

  defp field_value(_field, nil, _fleet_id), do: nil
  defp field_value(_field, [], _fleet_id), do: nil
  defp field_value("assignee_key", token_id, _fleet_id), do: key_or(token_id, nil)

  defp field_value(field, uri, fleet_id) when field in ["source_uri", "result_ref"],
    do: source(uri, fleet_id)

  defp field_value(field, value, _fleet_id) when is_map_key(@choices, field),
    do: choice(field, value)

  defp field_value(_field, value, _fleet_id), do: value(value)

  # A commit of the fleet's own code is shown as that commit, opened on this
  # site; a saved result of one of the fleet's notebooks as that result; any
  # other address as `value/1` shows it.
  defp source(nil, _fleet_id), do: nil

  defp source(uri, fleet_id) do
    hash = String.replace_prefix(uri, commit_url(fleet_id, ""), "")
    saved = String.replace_prefix(uri, Notebooks.url(fleet_id, "/results/"), "")

    cond do
      hash != uri and Code.full_hash?(hash) -> {:commit, hash, Code.commit_path(fleet_id, hash)}
      saved != uri and Regex.match?(@saved_result, saved) -> {:notebook_result, uri}
      true -> value(uri)
    end
  end

  # Text as written; an address with a scheme allowed for links is a link.
  defp value(value) when is_binary(value) do
    if link?(value), do: {:link, value}, else: value
  end

  defp value(values) when is_list(values), do: {:list, Enum.map(values, &value/1)}

  defp link?(value) do
    String.starts_with?(value, @link_schemes) and byte_size(value) <= 512 and
      not String.match?(value, ~r/[\s\x00-\x1f\x7f]/u)
  end

  @doc ~S|What a page calls one of a field's choices: `choice("progress", "doing")` is "In progress".|
  def choice(field, value), do: @choices |> Map.fetch!(field) |> Map.fetch!(value)

  defp key_or(token_id, _none) when is_integer(token_id), do: {:key, token_id, nil}
  defp key_or(nil, none), do: none

  defp discussion(links, fleet_id, opts) when is_list(links) and links != [] do
    rooms = fleet_id |> Rooms.list_rooms!(opts) |> Map.new(&{&1.slug, RoomsLive.room_label(&1)})

    for %{"room" => room, "seq" => seq} <- links, is_binary(room) and is_integer(seq) do
      name = rooms[room]

      %{
        room: name || room,
        seq: seq,
        path:
          if(name && Regex.match?(@room_slug, room),
            do: "#{Keyfleet.Fleets.path(fleet_id)}/rooms/#{room}"
          )
      }
    end
  end

  defp discussion(_links, _fleet_id, _opts), do: []

  defp other_end(%{source: object_id, target: other}, object_id), do: other
  defp other_end(%{source: other}, _object_id), do: other

  defp link_row(relation, object, titles) do
    outgoing? = relation.source == object.id
    other = if outgoing?, do: relation.target, else: relation.source

    %{
      id: relation.id,
      outgoing?: outgoing?,
      relation: relation_words(relation.type),
      type_name: elem(type_name(object.type), 0),
      other: item_part(other, titles)
    }
  end

  defp relation_words(type), do: Map.fetch!(@relations, type)

  # The ids a change's line names.
  defp mentions(%{brief: brief}),
    do:
      Enum.filter(
        [brief["object"], brief["source"], brief["target"], brief["task"]],
        &is_binary/1
      )

  defp line(event, titles, agents) do
    parts = event |> parts(titles) |> Enum.map(&named(&1, agents))
    %{seq: event.seq, at: at(event.timestamp), parts: parts}
  end

  # A review is told as its decision on the task, from its creation on the
  # board and from its link to the task in the task's history.
  defp parts(
         %{type: "object.created", brief: %{"object_type" => "review", "task" => task} = brief} =
           event,
         titles
       )
       when is_binary(task),
       do: reviewed(event, brief, task, titles)

  defp parts(
         %{
           type: "relation.created",
           brief: %{"relation_type" => "reviews", "target" => task} = brief
         } =
           event,
         titles
       )
       when is_binary(task),
       do: reviewed(event, brief, task, titles)

  defp parts(%{type: "object.created", brief: %{"object" => id} = brief} = event, titles)
       when is_binary(id) do
    {singular, _plural} = type_name(brief["object_type"])
    [who(event.actor), " added the #{singular} ", item_part(id, titles), "."]
  end

  defp parts(
         %{type: "patch.applied", brief: %{"object" => id, "archived" => true}} = event,
         titles
       )
       when is_binary(id),
       do: [who(event.actor), " archived ", item_part(id, titles), "."]

  defp parts(%{type: "patch.applied", brief: %{"object" => id, "joins" => joins}} = event, titles)
       when is_binary(id) and joins != 0,
       do: [
         who(event.actor),
         if(joins > 0, do: " joined ", else: " left "),
         item_part(id, titles),
         "."
       ]

  defp parts(
         %{type: "patch.applied", brief: %{"object" => id, "submitted" => true}} = event,
         titles
       )
       when is_binary(id),
       do: [who(event.actor), " submitted ", item_part(id, titles), " for review."]

  defp parts(%{type: "patch.applied", brief: %{"object" => id} = brief} = event, titles)
       when is_binary(id) do
    item = item_part(id, titles)
    type = titles[id] && titles[id].type

    case changes(brief, type) do
      [] -> [who(event.actor), " updated ", item, "."]
      changes -> [who(event.actor), " updated ", item, ": " | changes] ++ ["."]
    end
  end

  defp parts(
         %{type: type, brief: %{"source" => source, "target" => target} = brief} = event,
         titles
       )
       when type in ["relation.created", "relation.removed"] and is_binary(source) and
              is_binary(target) do
    words = relation_words(brief["relation_type"])

    {verb, joiner, clause} =
      if type == "relation.created",
        do: {" linked ", " to ", ", which it #{words}."},
        else: {" unlinked ", " from ", ", which it no longer #{words}."}

    [who(event.actor), verb, item_part(source, titles), joiner, item_part(target, titles), clause]
  end

  defp parts(%{type: "keyfleet.attention", brief: %{"kind" => kind, "object" => id}}, titles)
       when kind in ["task_unblocked", "needs_review"] do
    subject =
      case item_part(id, titles) do
        {:item, _id, nil} -> "An item"
        item -> item
      end

    [subject, if(kind == "task_unblocked", do: " is ready to start.", else: " needs review.")]
  end

  defp parts(%{type: "keyfleet.attention"}, _titles),
    do: ["Something in the workspace needs attention."]

  defp parts(_event, _titles), do: ["The workspace changed."]

  defp reviewed(event, brief, task, titles) do
    did = if brief["decision"] == "accept", do: " accepted ", else: " disputed "
    [who(event.actor), did, item_part(task, titles), "."]
  end

  # What a change changed, in the order the fields are shown, with the new
  # value of the few short fields.
  defp changes(brief, type) do
    order = @fields |> Map.get(type, []) |> Enum.map(&elem(&1, 0))
    values = brief["values"]

    brief["fields"]
    |> Enum.reject(&(&1 == "sys"))
    |> Enum.sort_by(&(Enum.find_index(order, fn field -> field == &1 end) || length(order)))
    |> Enum.map(&change(&1, field_label(type, &1), values[&1]))
    |> Enum.intersperse([", "])
    |> List.flatten()
  end

  defp change("assignee_key", _label, %{"new" => token_id}) when is_integer(token_id),
    do: ["now taken by ", {:key, token_id, nil}]

  # A field set to nothing has no new value.
  defp change("assignee_key", _label, %{} = value) when not is_map_key(value, "new"),
    do: ["now taken by no one"]

  defp change(field, label, %{"new" => new}) when is_binary(new),
    do: [String.downcase(label) <> " is now " <> String.downcase(choice(field, new))]

  defp change(_field, label, _value), do: [String.downcase(label)]

  defp field_label(type, field) do
    case List.keyfind(Map.get(@fields, type, []), field, 0) do
      {^field, label} -> label
      nil -> if field == "title", do: "Title", else: humanize(field)
    end
  end

  defp item_part(id, titles) do
    case titles[id] do
      nil -> {:item, id, nil}
      object -> {:item, id, object.title}
    end
  end

  # A member's change names the key it was made as, with the agent's wallet
  # when an agent wrote as it (`named/2` puts its name in); anything else was
  # the workspace's own doing.
  defp who(actor) do
    case Graph.Event.member(actor) do
      {token_id, kind, wallet} -> {:by, token_id, agent_wallet(kind, wallet)}
      nil -> "Keyfleet"
    end
  end

  defp named({:by, token_id, wallet}, agents), do: {:key, token_id, agents[wallet]}
  defp named(part, _agents), do: part

  # The key an item was added as, with the name of the agent that added it.
  defp created_by(%{"created_by" => %{"key" => %{"token_id" => token_id}}} = sys, agents),
    do: {:key, token_id, agents[creator_wallet(sys)]}

  defp creator_wallet(%{"created_by" => by}), do: agent_wallet(by["kind"], by["wallet"])

  # Who joined a goal, in the order they joined, each told as the key it
  # joined as with the name of its agent.
  defp joined(sys), do: Map.get(sys, "joined", [])

  defp joined_wallets(sys), do: Enum.map(joined(sys), &agent_wallet(&1["kind"], &1["wallet"]))

  defp joined_field(sys, agents) do
    case joined(sys) do
      [] ->
        []

      members ->
        keys =
          for member <- members,
              do:
                {:key, member["key"]["token_id"],
                 agents[agent_wallet(member["kind"], member["wallet"])]}

        [{"Joined", {:list, keys}}]
    end
  end

  defp joined_fact(sys) do
    case length(joined(sys)) do
      0 -> []
      count -> [{"Joined", Integer.to_string(count)}]
    end
  end

  defp actor_wallet(event) do
    case who(event.actor) do
      {:by, _token_id, wallet} -> wallet
      "Keyfleet" -> nil
    end
  end

  defp agent_wallet("agent", wallet), do: wallet
  defp agent_wallet(_kind, _wallet), do: nil

  @doc """
  The names agents gave themselves, by wallet, looked up together for a
  page. A person, or an agent that has no profile here, has no name.
  Agents choose their own names, so none can hide or reverse the Key beside it.
  """
  def agent_names(wallets) do
    wallets
    |> Agents.names_by_wallet()
    |> Map.new(fn {wallet, name} -> {wallet, DirectoryMD.visible(name)} end)
  end

  defp archived?(sys), do: sys["archived"] == true

  defp level(%{"scope" => scope}) do
    case Regex.run(@level, scope, capture: :all_but_first) do
      [level] -> String.to_integer(level)
      nil -> nil
    end
  end

  # A push an agent sent names the agent beside its Key.
  defp pushes(pushes, fleet_id) do
    agents = agent_names(Enum.map(pushes, & &1.acting_agent_wallet))
    Enum.map(pushes, &push(&1, fleet_id, agents))
  end

  # The log stamps every event in UTC.
  defp push(push, fleet_id, agents) do
    %{
      id: push.id,
      token_id: push.token_id,
      agent: agents[push.acting_agent_wallet],
      what: moved(push.ref),
      commit: {:commit, push.head, Code.commit_path(fleet_id, push.head)},
      at: Calendar.strftime(push.pushed_at, @at)
    }
  end

  defp moved("refs/heads/" <> branch), do: "changes to " <> branch
  defp moved("refs/tags/" <> tag), do: "the tag " <> tag
  defp moved(ref), do: ref

  defp at(timestamp) do
    {:ok, datetime, 0} = DateTime.from_iso8601(timestamp)
    Calendar.strftime(datetime, @at)
  end

  defp humanize(field), do: field |> String.replace("_", " ") |> String.capitalize()
end
