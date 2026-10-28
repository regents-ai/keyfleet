defmodule Keyfleet.CodeHistory do
  @moduledoc """
  A repository's history as the code store answers it, for tests: commits
  along one line, newest first, read a page at a time
  (`Keyfleet.Code.NodeClient.commits/3`) or one by one
  (`Keyfleet.Code.NodeClient.commit/3`).
  """
  import Plug.Conn

  @doc """
  The `n`th commit of a line: its hash, its writer, when it was written,
  its message, the commit before it, and the one file it changed.
  """
  def commit(n) do
    %{
      "hash" => hash(n),
      "parents" => if(n > 1, do: [hash(n - 1)], else: []),
      "author" => "Ada <ada@example.com>",
      "date" => "2026-10-28T12:0#{rem(n, 10)}:00Z",
      "committed" => "2026-10-28T12:0#{rem(n, 10)}:00Z",
      "message" => "Step #{n}\n\nWhy step #{n} was taken.\n",
      "files" => [
        %{
          "path" => "steps/#{n}.txt",
          "old_path" => nil,
          "status" => "added",
          "additions" => 1,
          "deletions" => 0,
          "binary" => false,
          "patch" => "@@ -0,0 +1 @@\n+step #{n}\n",
          "patch_truncated" => false
        }
      ],
      "files_truncated" => false
    }
  end

  def hash(n), do: :sha |> :crypto.hash("step #{n}") |> Base.encode16(case: :lower)

  @doc """
  Answers a request for `commits` (newest first): `[]` is a page of the
  history, from `ref` (the newest when none), leaving out what any commit in
  `not` reaches, after `skip`, at most `limit`; `[hash]` is that one commit.
  """
  def answer(conn, commits, []) do
    params = fetch_query_params(conn).query_params
    hashes = Enum.map(commits, & &1["hash"])
    start = if params["ref"], do: Enum.find_index(hashes, &(&1 == params["ref"])), else: 0
    left_out = params |> Map.get("not", "") |> String.split(",", trim: true)

    if start == nil or Enum.any?(left_out, &(&1 not in hashes)) do
      send_resp(conn, 404, "")
    else
      line =
        commits
        |> Enum.drop(start)
        |> Enum.take_while(&(&1["hash"] not in left_out))

      skip = String.to_integer(Map.get(params, "skip", "0"))
      limit = String.to_integer(params["limit"])

      Req.Test.json(conn, %{
        "head" => commits |> Enum.at(start, %{}) |> Map.get("hash"),
        "commits" =>
          for commit <- line |> Enum.drop(skip) |> Enum.take(limit) do
            commit
            |> Map.take(["hash", "author", "date"])
            |> Map.put("message", commit["message"] |> String.split("\n") |> hd())
          end,
        "more" => length(line) > skip + limit
      })
    end
  end

  def answer(conn, commits, [hash]) do
    case Enum.find(commits, &(&1["hash"] == hash)) do
      nil -> send_resp(conn, 404, "")
      commit -> Req.Test.json(conn, commit)
    end
  end
end
