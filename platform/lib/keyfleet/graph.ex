defmodule Keyfleet.Graph do
  @moduledoc """
  Each fleet's shared workspace, kept in the fleet's own graph.

  Every call names its fleet. Writes go to the fleet's graph; a write names the
  key it acts as, `as_key`, and its own command id; see
  `Keyfleet.Graph.Workspace`. Reads are for the fleet's members, except the
  summary a fleet shows anyone (`Keyfleet.Graph.Checks.KeyReader`), and are
  answered from read tables the projector keeps copied from the graph's log,
  so a read never waits on a write. Each read says how far along the log it reflects, its
  `watermark`.
  """
  use Ash.Domain

  @goals_shown 3
  @open_work [:goals_open, :tasks_doing, :tasks_taken, :tasks_untaken]
  @tables [
    Keyfleet.Graph.Cursor,
    Keyfleet.Graph.Event,
    Keyfleet.Graph.Object,
    Keyfleet.Graph.Relation
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
      define :join_goal, action: :join, args: [:fleet_id]
      define :leave_goal, action: :leave, args: [:fleet_id]
      define :submit_task, action: :submit, args: [:fleet_id]
      define :review_task, action: :review, args: [:fleet_id]
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
      define :goal_work, action: :around_goal, args: [:fleet_id, :goal_id]
      define :object_titles, action: :titled, args: [:fleet_id, :ids]
      define :open_work, action: :open_work, args: [:fleet_id, :kind]
      define :outline, action: :outline, args: [:fleet_id, :type]
      define :evidence_citing, action: :citing, args: [:fleet_id, :uri]
      define :tasks_assigned_to, action: :assigned_to_keys, args: [:fleet_id, :token_ids]
      define :goals_joined_by, action: :joined_by, args: [:fleet_id, :token_id, :wallet]
      define :project_objects, action: :project
    end

    resource Keyfleet.Graph.Relation do
      define :read_relations_touching,
        action: :touching,
        args: [:fleet_id, :object_id, :after_seq, :limit]

      define :object_links, action: :linked, args: [:fleet_id, :object_id]
      define :producers_of, action: :producing, args: [:fleet_id, :targets]
      define :project_relations, action: :project
      define :remove_relations, action: :remove
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
  goal comes with its `title`.

  This is the one place the rule lives; `trying_now/1` answers the same
  question from the goals it reads.
  """
  def open_question(fleet_id), do: fleet_id |> open_goals(1) |> question_of()

  @doc """
  What a fleet shows anyone of what its agents are trying to do right now,
  read from one snapshot (`in_snapshot/1`), with no text beyond titles and
  the open question:

    * `goals`: up to #{@goals_shown} open goals, most recently changed first,
      each with its `title`.
    * `goals_set?`: whether the workspace holds any goal, open or not, that
      is not archived.
    * `counts`: how many of each kind of open work the workspace holds, as
      `count_open_work/2` counts them: `goals_open`, `tasks_doing`,
      `tasks_taken` and `tasks_untaken`.
    * `question`: the question `open_question/1` gives, or nil.

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

  defp read_trying_now(fleet_id) do
    goals = open_goals(fleet_id, @goals_shown)

    counts =
      Map.new(@open_work, fn kind ->
        case count_open_work(fleet_id, kind) do
          {:ok, count} -> {kind, count}
          {:error, failure} -> raise failure
        end
      end)

    %{
      goals: goals,
      goals_set?: goals != [] or outline!(fleet_id, "goal", query: [limit: 1]) != [],
      counts: counts,
      question: goals |> question_of() |> then(&(&1 && &1.question))
    }
  end

  defp open_goals(fleet_id, limit) do
    open_work!(fleet_id, :goals_open, query: [limit: limit], load: [:first_open_question])
  end

  defp question_of([%{first_open_question: question} = goal | _]) when is_binary(question),
    do: %{goal: goal, question: question}

  defp question_of(_goals), do: nil

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
  Where a fleet tells its members how far its workspace's read tables have
  reached, as `{:graph_head, fleet_id, run_id, watermark}`: the log they copy
  and the place in it. A notice is only a hint to read again; a reader that
  misses one loses nothing, because it reads on from its own cursor.
  """
  def head_topic(fleet_id), do: "fleet:#{fleet_id}:graph"

  @doc """
  Where a fleet tells anyone that its activity has a new workspace change to
  show them (`notable_before/3`), as `{:graph_notable, fleet_id}`. It says
  nothing of any other change, nor how far the log has got.
  """
  def notable_topic(fleet_id), do: "fleet:#{fleet_id}:graph:notable"

  @doc """
  Where a reader of `class` (`Keyfleet.Access.class/2`) hears of the fleet's
  workspace: `head_topic/1` for whoever reads the workspace, `notable_topic/1`
  for anyone else. A listener is on one of the two, never both.
  """
  def topic(fleet_id, class) do
    if Keyfleet.Access.enough?(class, :read, :workspace),
      do: head_topic(fleet_id),
      else: notable_topic(fleet_id)
  end
end
