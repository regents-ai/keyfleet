defmodule Keyfleet.Graph do
  @moduledoc """
  Each fleet's shared workspace, kept in the fleet's own graph.

  Every call names its fleet. Writes go to the fleet's graph; a write names the
  key it acts as, `as_key`, and its own command id; see
  `Keyfleet.Graph.Workspace`. Reads are open to anyone and are answered from
  read tables the projector keeps copied from the graph's log, so a read never
  waits on a write. Each read says how far along the log it reflects, its
  `watermark`.
  """
  use Ash.Domain

  @goals_shown 3
  @tasks_per_goal 5
  @taken_shown 8
  @findings_shown 3
  @problems_shown 3
  @tables [
    Keyfleet.Graph.Cursor,
    Keyfleet.Graph.Event,
    Keyfleet.Graph.Object,
    Keyfleet.Graph.Relation,
    Keyfleet.Graph.LaunchPlanRevision
  ]

  resources do
    resource Keyfleet.Graph.Workspace do
      define :get_object, action: :get, args: [:fleet_id, :id]
      define :list_changes, action: :changes, args: [:fleet_id]
      define :create_object, action: :create, args: [:fleet_id]
      define :patch_object, action: :patch, args: [:fleet_id]
      define :link_objects, action: :link, args: [:fleet_id]
      define :unlink_relation, action: :unlink, args: [:fleet_id]
      define :archive_object, action: :archive, args: [:fleet_id]
    end

    resource Keyfleet.Graph.Cursor do
      define :get_cursor, action: :read, get_by: [:fleet_id], not_found_error?: false
      define :start_cursor, action: :start
      define :advance_cursor, action: :advance
      define :forget_cursor, action: :forget
    end

    resource Keyfleet.Graph.Event do
      define :read_events, action: :page, args: [:fleet_id, :after_seq, :limit]
      define :latest_activity, action: :activity, args: [:fleet_id]
      define :notable_before, action: :notable_before, args: [:fleet_id, :before_seq, :limit]
      define :latest_mark, action: :latest_mark, args: [:fleet_id, :mark], not_found_error?: false
      define :object_history, action: :history, args: [:fleet_id, :object_id]
      define :record_events, action: :record
    end

    resource Keyfleet.Graph.Object do
      define :read_object, action: :in_fleet, args: [:fleet_id, :id], not_found_error?: false
      define :read_objects, action: :with_ids, args: [:fleet_id, :ids]
      define :workspace_cards, action: :cards, args: [:fleet_id]
      define :object_titles, action: :titled, args: [:fleet_id, :ids]
      define :open_work, action: :open_work, args: [:fleet_id, :kind]
      define :proposable_launch_plans, action: :launch_plans, args: [:fleet_id]
      define :tasks_assigned_to, action: :assigned_to_keys, args: [:fleet_id, :token_ids]
      define :project_objects, action: :project
    end

    resource Keyfleet.Graph.Relation do
      define :read_relations_touching, action: :touching, args: [:fleet_id, :object_id, :limit]
      define :links_of_type, action: :of_type, args: [:fleet_id, :type, :limit]
      define :object_links, action: :linked, args: [:fleet_id, :object_id]
      define :project_relations, action: :project
      define :remove_relations, action: :remove
    end

    resource Keyfleet.Graph.LaunchPlanRevision do
      define :launch_plan_revisions, action: :for_digests, args: [:fleet_id, :digests]

      define :current_launch_plan_revisions, action: :current_for, args: [:fleet_id, :plans]

      define :project_launch_plan_revisions, action: :project
    end
  end

  @doc """
  How many objects of one kind of open work the fleet's workspace holds:
  `:goals_open`, `:tasks_doing`, `:tasks_taken` or `:tasks_untaken`, as the
  `:open_work` read of `Keyfleet.Graph.Object` defines them, as `{:ok,
  count}` or `{:error, failure}` (see `Keyfleet.Count`).
  """
  def count_open_work(fleet_id, kind) do
    Keyfleet.Graph.Object
    |> Ash.Query.for_read(:open_work, %{fleet_id: fleet_id, kind: kind})
    |> Keyfleet.Count.of()
  end

  @doc """
  The first open question of the fleet's newest open goal, with that goal:
  `%{goal: goal, question: question}`, or nil when the fleet has no open goal
  or its newest one has no open question. The newest open goal is the one
  changed most recently among the `:goals_open` of the `:open_work` read. The
  goal comes with its `title` and `card`.

  This is the one place the rule lives; `trying_now/1` answers the same
  question from the goals it reads.
  """
  def open_question(fleet_id), do: fleet_id |> open_goals(1) |> question_of()

  @doc """
  What the fleet's agents are trying to do right now, read from one snapshot
  (`in_snapshot/1`) in six bounded queries, with no text beyond each card's
  `gist`:

    * `goals`: up to #{@goals_shown} open goals, most recently changed first,
      each with up to #{@tasks_per_goal} of the tasks linked to it by
      `implements`, the newest link first: `%{goal: goal, tasks: [%{task:
      task, assignee_key: key | nil, progress: progress}]}`. Archived tasks
      aren't listed.
    * `taken`: who's on what: up to #{@taken_shown} tasks in progress that
      a key has taken (`:tasks_taken`), `%{task: task, assignee_key: key}`.
    * `findings`: the #{@findings_shown} most recently changed findings.
    * `problems`: the #{@problems_shown} newest `contradicts` links still in
      place, `%{relation: link, source: object, target: object}`. Unlinking
      removes a link, so an unlinked problem is gone; a link from or to an
      archived object isn't listed.
    * `question`: the question `open_question/1` gives, or nil.

  Every object comes with its `title` and `card`.

  Never call it inside a transaction: its snapshot has to be its
  transaction's first statement. Inside an ordinary transaction that fails
  loudly; inside a repeatable-read one it doesn't fail, but reads that
  transaction's snapshot, taken at its first query, rather than one of its
  own. The outer transaction can write again once it returns.
  """
  def trying_now(fleet_id) do
    {:ok, now} = in_snapshot(fn -> read_trying_now(fleet_id) end)
    now
  end

  @doc "How many of a goal's tasks `trying_now/1` lists at most: a goal listing this many may have more."
  def tasks_per_goal, do: @tasks_per_goal

  defp read_trying_now(fleet_id) do
    goals = open_goals(fleet_id, @goals_shown, links_in: implementing_tasks())
    problems = links_of_type!(fleet_id, "contradicts", @problems_shown)

    objects =
      goals
      |> Enum.flat_map(fn goal -> Enum.map(goal.links_in, & &1.source) end)
      |> Enum.concat(Enum.flat_map(problems, &[&1.source, &1.target]))
      |> Enum.uniq()
      |> then(&object_titles!(fleet_id, &1, load: [:card]))
      |> Map.new(&{&1.id, &1})

    taken = open_work!(fleet_id, :tasks_taken, query: [limit: @taken_shown])
    findings = workspace_cards!(fleet_id, %{type: "finding"}, page: [limit: @findings_shown])

    %{
      goals: Enum.map(goals, &%{goal: &1, tasks: tasks(&1, objects)}),
      taken: Enum.map(taken, &%{task: &1, assignee_key: &1.card["assignee_key"]}),
      findings: findings.results,
      problems: problems(problems, objects),
      question: goals |> question_of() |> then(&(&1 && &1.question))
    }
  end

  defp open_goals(fleet_id, limit, load \\ []) do
    open_work!(fleet_id, :goals_open,
      query: [limit: limit],
      load: [:first_open_question | load]
    )
  end

  defp question_of([%{first_open_question: question} = goal | _]) when is_binary(question),
    do: %{goal: goal, question: question}

  defp question_of(_goals), do: nil

  # Each goal's newest links from tasks that implement it, at most
  # @tasks_per_goal of them per goal, in one query for all the goals read.
  defp implementing_tasks do
    Keyfleet.Graph.Relation
    |> Ash.Query.for_read(:into, %{type: "implements", source_type: "task"})
    |> Ash.Query.limit(@tasks_per_goal)
  end

  # Every link read names objects in the same snapshot, so each is there.
  defp tasks(goal, objects) do
    for %{source: id} <- goal.links_in do
      task = Map.fetch!(objects, id)
      %{task: task, assignee_key: task.card["assignee_key"], progress: task.card["progress"]}
    end
  end

  defp problems(links, objects) do
    for link <- links do
      %{
        relation: link,
        source: Map.fetch!(objects, link.source),
        target: Map.fetch!(objects, link.target)
      }
    end
  end

  @doc """
  Runs `read` in one read-only snapshot of the workspace's read tables and
  answers `{:ok, result}`: Postgres fixes a repeatable-read snapshot at the
  transaction's first query, so everything `read` reads comes from one
  moment. Never call it inside a transaction: the setting has to be the
  transaction's first statement. Inside an ordinary transaction that fails
  loudly; inside a repeatable-read one it doesn't fail, but `read` sees that
  transaction's snapshot, taken at its first query, rather than one of its
  own. The read-only setting ends with `read`: the outer transaction can
  write again once it returns.
  """
  def in_snapshot(read) do
    Ash.transact(@tables, fn ->
      Keyfleet.Repo.query!("SET TRANSACTION ISOLATION LEVEL REPEATABLE READ, READ ONLY")
      read.()
    end)
  end

  @doc """
  Where a fleet says how far its workspace's read tables have reached, as
  `{:graph_head, fleet_id, run_id, watermark}`: the log they copy and the
  place in it. A notice is only a hint to read again; a reader that misses one
  loses nothing, because it reads on from its own cursor.
  """
  def head_topic(fleet_id), do: "fleet:#{fleet_id}:graph"
end
