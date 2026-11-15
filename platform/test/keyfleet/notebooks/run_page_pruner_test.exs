defmodule Keyfleet.Notebooks.RunPagePrunerTest do
  # Once a day the copies of background runs' pages older than 30 days are
  # cleared, except what the notebooks' reads answer from them: each
  # notebook's newest run page (a listed notebook's `state` and its page
  # read) and its newest page of a run that succeeded (`last_succeeded`). A
  # version's page and a page a Key made public stay whatever their age.
  use ExUnit.Case, async: false
  use ExUnitProperties
  use Oban.Testing, repo: Keyfleet.Repo

  alias Keyfleet.Actors.System
  alias Keyfleet.Notebooks
  alias Keyfleet.Notebooks.{RunPagePruner, SavedOutput}
  alias Keyfleet.Projects.Publication

  @fleet "fleet_tech_classic"
  @other_fleet "fleet_regents_club"
  @notebook "nb-0123456789abcdef"
  @busy "nb-fedcba9876543210"
  @day 86_400_000

  setup do
    :ok = Ecto.Adapters.SQL.Sandbox.checkout(Keyfleet.Repo)
  end

  # Costly failure: a notebook's state, page or last good result gone; a
  # public page, a version's page or a recent result cleared; or a page past
  # its time kept for good.
  test "clears old run pages and keeps what the notebooks' reads answer, a version's and a public page" do
    now = now()

    copies = [
      # An older good run, with a newer good one: cleared.
      {@fleet, @notebook, run(1), now - 60 * @day, true},
      # Public, so kept, though old and not good.
      {@fleet, @notebook, run(2), now - 50 * @day, false},
      # Neither newest nor good: cleared, though its address is public in
      # another fleet.
      {@fleet, @notebook, run(3), now - 45 * @day, false},
      # The notebook's newest good run page.
      {@fleet, @notebook, run(4), now - 40 * @day, true},
      # The notebook's newest run page, failed.
      {@fleet, @notebook, run(5), now - 35 * @day, false},
      # A version's page is never a run's.
      {@fleet, @notebook, version(1), now - 90 * @day, false},
      # Past 30 days with a newer run: cleared.
      {@fleet, @busy, run(6), now - 31 * @day, false},
      # Under 30 days: kept.
      {@fleet, @busy, run(7), now - 29 * @day, false},
      {@fleet, @busy, run(8), now - @day, true},
      # The same notebook in another fleet has only this one: its newest.
      {@other_fleet, @notebook, run(9), now - 70 * @day, false}
    ]

    for {fleet_id, notebook_id, source_id, saved_at, succeeded} <- copies do
      Notebooks.keep_saved_output!(
        fleet_id,
        notebook_id,
        source_id,
        saved_at,
        "<p>#{source_id}</p>",
        succeeded,
        actor: %System{}
      )
    end

    Notebooks.record_run_failure(@fleet, run(5), %{"stage" => "export", "message" => "Stopped."})
    publish!(@fleet, @notebook, run(2), now - 50 * @day)
    publish!(@other_fleet, @notebook, run(3), now - 45 * @day)

    before = reads()

    kept = [
      {@other_fleet, @notebook, run(9)},
      {@fleet, @notebook, run(2)},
      {@fleet, @notebook, run(4)},
      {@fleet, @notebook, run(5)},
      {@fleet, @notebook, version(1)},
      {@fleet, @busy, run(7)},
      {@fleet, @busy, run(8)}
    ]

    for _twice <- 1..2 do
      assert :ok = perform_job(RunPagePruner, %{})
      assert copies() == kept
      assert reads() == before
    end
  end

  # Costly failure: clearing changes what a notebook's state, page read or
  # last good page answers, for some mix of runs nobody thought of.
  property "a notebook's newest run page and newest good page answer the same after clearing" do
    check all copies <- list_of(copy(), min_length: 1, max_length: 8), max_runs: 60 do
      fleet_id = "fleet_p#{Elixir.System.unique_integer([:positive])}"
      now = now()

      copies =
        copies
        |> Enum.with_index(1)
        |> Enum.map(fn {{kind, days, succeeded, public}, n} ->
          source_id = if kind == :run, do: run(n), else: version(n)
          # Each copy made at its own moment, so no two tie.
          saved_at = now - days * @day - n
          %{source_id: source_id, saved_at: saved_at, succeeded: succeeded, public: public}
        end)

      for copy <- copies do
        Notebooks.keep_saved_output!(
          fleet_id,
          @notebook,
          copy.source_id,
          copy.saved_at,
          "<p>#{copy.source_id}</p>",
          copy.succeeded,
          actor: %System{}
        )

        if copy.public, do: publish!(fleet_id, @notebook, copy.source_id, copy.saved_at)
      end

      before = notebook_reads(fleet_id, [@notebook])
      assert :ok = perform_job(RunPagePruner, %{})
      assert notebook_reads(fleet_id, [@notebook]) == before

      runs = Enum.filter(copies, &String.starts_with?(&1.source_id, "run_"))
      newest = runs |> Enum.max_by(& &1.saved_at, fn -> nil end)

      newest_good =
        runs |> Enum.filter(& &1.succeeded) |> Enum.max_by(& &1.saved_at, fn -> nil end)

      expected =
        for copy <- copies,
            not String.starts_with?(copy.source_id, "run_") or copy.public or
              copy.saved_at >= now - 30 * @day or copy in [newest, newest_good],
            do: {fleet_id, @notebook, copy.source_id}

      assert Enum.filter(copies(), &(elem(&1, 0) == fleet_id)) == Enum.sort(expected)
    end
  end

  # A run's or a version's page, how many days old, whether it succeeded,
  # and whether a Key made it public. 30 days exactly is left out: whether
  # that page goes depends on the millisecond the job runs.
  defp copy do
    gen all kind <- member_of([:run, :run, :run, :version]),
            days <- one_of([integer(0..29), integer(31..120)]),
            succeeded <- boolean(),
            public <- frequency([{4, constant(false)}, {1, constant(true)}]) do
      {kind, days, kind == :run and succeeded, public}
    end
  end

  # What a notebook's state and page read (`:newest_runs`, page and all) and
  # its last good page (`:last_succeeded`) answer, for each fleet here.
  defp reads do
    Map.new([@fleet, @other_fleet], &{&1, notebook_reads(&1, [@notebook, @busy])})
  end

  defp notebook_reads(fleet_id, notebook_ids) do
    newest =
      Notebooks.newest_run_outputs!(fleet_id, notebook_ids,
        query: Ash.Query.select(SavedOutput, [:page]),
        actor: %System{}
      )

    good = Notebooks.last_succeeded_outputs!(fleet_id, notebook_ids, actor: %System{})

    %{
      newest: newest |> Enum.map(&facts/1) |> Enum.sort(),
      good: good |> Enum.map(&Map.take(&1, [:notebook_id, :source_id, :saved_at])) |> Enum.sort()
    }
  end

  defp facts(copy),
    do: Map.take(copy, [:id, :notebook_id, :source_id, :saved_at, :succeeded, :failure, :page])

  defp copies do
    SavedOutput
    |> Ash.Query.select([:fleet_id, :notebook_id, :source_id])
    |> Ash.read!(actor: %System{})
    |> Enum.map(&{&1.fleet_id, &1.notebook_id, &1.source_id})
    |> Enum.sort()
  end

  defp publish!(fleet_id, notebook_id, source_id, saved_at) do
    Publication
    |> Ash.Changeset.for_create(
      :record,
      %{
        fleet_id: fleet_id,
        project: "general",
        key: 3,
        author_wallet: "0x" <> String.duplicate("a", 40),
        kind: :page,
        page: Notebooks.result_path(notebook_id, source_id, saved_at)
      },
      actor: %System{}
    )
    |> Ash.create!()
  end

  defp now, do: DateTime.to_unix(DateTime.utc_now(), :millisecond)

  defp run(n), do: "run_" <> String.pad_leading(Integer.to_string(n), 26, "0")
  defp version(n), do: "ver_" <> String.pad_leading(Integer.to_string(n), 26, "0")
end
