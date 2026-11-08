# Property test on the code store's real push rule: the pre-receive hook in
# regents-ai/keyfleet-code (infra/keyfleet/hooks/pre-receive), which the
# store's image sets as git's core.hooksPath. Random pushes into a scratch
# store: adding commits, branches and tags, force pushes, deletes and moved
# tags. Uses git only; nothing leaves the machine.
#
#   elixir code_store_properties.exs <path to the pre-receive hook>
#
# ActionGuards' CodeStoreOnlyAdds takes this rule from here: a push is taken
# exactly when every ref it changes is new or moves a branch forward, and a
# taken push never removes a ref, moves a tag or rewrites a branch.

Mix.install([{:stream_data, "~> 1.4"}])

hook =
  case System.argv() do
    [hook] -> Path.expand(hook)
    _ -> raise ArgumentError, "usage: elixir code_store_properties.exs <pre-receive hook>"
  end

Application.put_env(:keyfleet_formal, :hook, hook)
ExUnit.start(seed: String.to_integer(System.get_env("SEED", "0")))

defmodule Keyfleet.CodeStorePropertiesTest do
  use ExUnit.Case
  use ExUnitProperties

  @branches ["main", "side"]
  @tags ["v1", "v2"]

  defp git(dir, args) do
    {out, status} =
      System.cmd("git", ["-c", "user.name=t", "-c", "user.email=t@t", "-c", "commit.gpgsign=false"] ++ args,
        cd: dir,
        stderr_to_stdout: true,
        env: [{"GIT_CONFIG_NOSYSTEM", "1"}, {"GIT_CONFIG_GLOBAL", "/dev/null"}]
      )

    {String.trim(out), status}
  end

  defp refs(store) do
    {out, 0} = git(store, ["for-each-ref", "--format=%(refname) %(objectname)"])

    for line <- String.split(out, "\n", trim: true), into: %{} do
      [ref, sha] = String.split(line, " ")
      {ref, sha}
    end
  end

  defp ancestor?(store, old, new), do: elem(git(store, ["merge-base", "--is-ancestor", old, new]), 1) == 0

  # One push: a list of {ref, target}, target being a commit index or :delete.
  defp push_gen do
    ref = StreamData.member_of(Enum.map(@branches, &"refs/heads/#{&1}") ++ Enum.map(@tags, &"refs/tags/#{&1}"))
    target = StreamData.one_of([StreamData.integer(0..4), StreamData.constant(:delete)])
    StreamData.list_of(StreamData.tuple({ref, target}), min_length: 1, max_length: 3)
    |> StreamData.map(&Enum.uniq_by(&1, fn {ref, _} -> ref end))
  end

  setup do
    dir = Path.join(System.tmp_dir!(), "kf-code-store-#{System.unique_integer([:positive])}")
    File.mkdir_p!(dir)
    on_exit(fn -> File.rm_rf!(dir) end)

    {_, 0} = git(dir, ["init", "-q", "--bare", "store.git"])
    store = Path.join(dir, "store.git")
    {_, 0} = git(store, ["config", "core.hooksPath", Path.dirname(Application.fetch_env!(:keyfleet_formal, :hook))])
    {_, 0} = git(dir, ["init", "-q", "work"])
    work = Path.join(dir, "work")

    # Five commits on two lines of history: c0-c1-c2 and c0-c3-c4.
    commit = fn message ->
      {_, 0} = git(work, ["commit", "-q", "--allow-empty", "-m", message])
      {sha, 0} = git(work, ["rev-parse", "HEAD"])
      sha
    end

    c0 = commit.("c0")
    c1 = commit.("c1")
    c2 = commit.("c2")
    {_, 0} = git(work, ["checkout", "-q", "--detach", c0])
    c3 = commit.("c3")
    c4 = commit.("c4")
    shas = [c0, c1, c2, c3, c4]

    %{store: store, work: work, shas: List.to_tuple(shas)}
  end

  property "a push is taken exactly when it only adds, and the store never loses or rewrites a ref",
           %{store: store, work: work, shas: shas} do
    check all pushes <- StreamData.list_of(push_gen(), min_length: 1, max_length: 6), max_runs: 60 do
      Enum.each(pushes, fn push ->
        before = refs(store)
        # Git itself refuses to delete a ref the store doesn't have.
        push = Enum.reject(push, fn {ref, t} -> t == :delete and not Map.has_key?(before, ref) end)
        check_push(push, before, store, work, shas)
      end)
    end
  end

  defp check_push([], _before, _store, _work, _shas), do: :ok

  defp check_push(push, before, store, work, shas) do
    additive? =
      Enum.all?(push, fn
        {_ref, :delete} ->
          false

        {ref, i} ->
          sha = elem(shas, i)

          case before[ref] do
            nil -> true
            ^sha -> true
            old -> String.starts_with?(ref, "refs/heads/") and ancestor?(work, old, sha)
          end
      end)

    specs = for {ref, t} <- push, do: if(t == :delete, do: ":" <> ref, else: "+#{elem(shas, t)}:#{ref}")
    {_out, status} = git(work, ["push", "--porcelain", "--atomic", "../store.git" | specs])
    later = refs(store)

    if additive? do
      assert status == 0
    else
      assert status != 0
      assert later == before
    end

    for {ref, old} <- before do
      assert Map.has_key?(later, ref), "#{ref} was removed"
      new = later[ref]
      if String.starts_with?(ref, "refs/tags/"), do: assert(new == old, "#{ref} moved")
      assert ancestor?(work, old, new), "#{ref} was rewritten"
    end
  end
end
