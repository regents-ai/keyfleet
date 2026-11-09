defmodule KeyfleetWeb.AgentTools.Code.Answer do
  @moduledoc """
  A project's code as an agent reads it, the same over its signed requests
  and as the Claude connector's tools (`KeyfleetWeb.AgentTools.Code`): the
  changes sent lately to its repository, each with the address a workspace
  cites its commit by (`:pushes`); its history (`:commits`); and one commit
  with what it changed (`:commit`), read as the commit page and the history
  page read them (`KeyfleetWeb.WorkspacePage`). Git itself reaches the code
  through `KeyfleetWeb.Plugs.CodeGateway`. Each answer is
  `{status, body, nil}`; `params` is the signed request's JSON, its body
  with the names in its address.
  """

  alias Keyfleet.Actors.{Agent, System}
  alias Keyfleet.{Code, Fleets, Projects}
  alias KeyfleetWeb.{Endpoint, NotFoundError, Refusal, WorkspacePage}

  @doc "Answers `op` for `actor`; nothing here waits, so the waiter is unused."
  @spec answer(atom(), map(), Agent.t(), term()) :: {pos_integer(), map(), nil}
  def answer(:pushes, %{"fleet_id" => fleet_id, "project" => project}, actor, _waiter) do
    with {:ok, %{}} <- Fleets.get_fleet(fleet_id, actor: %System{}),
         {:ok, pushes} <- Code.recent_pushes(fleet_id, project, actor: actor),
         {:project, {:ok, %{repository: repository}}} <-
           {:project, Projects.project(fleet_id, project, actor: actor)} do
      ok(%{
        pushes:
          for push <- pushes do
            %{
              ref: push.ref,
              commit: push.head,
              commit_url: WorkspacePage.commit_url(fleet_id, repository, push.head),
              token_id: push.token_id,
              pushed_at: push.pushed_at
            }
          end
      })
    else
      {:ok, nil} -> Refusal.answer(404, "fleet_unknown")
      {:project, {:ok, nil}} -> Refusal.answer(404, "project_unknown")
      {:project, failed} -> refused(fleet_id, failed)
      failed -> refused(fleet_id, failed)
    end
  end

  # The history's first page is {}; next names the page after it.
  def answer(:commits, %{"fleet_id" => fleet_id} = params, actor, _waiter) do
    case repository(fleet_id, params["project"]) do
      {:ok, repository} ->
        fleet_id
        |> WorkspacePage.history(repository, params["from"], Map.get(params, "page", 1), actor)
        |> case do
          %{members_only?: true} ->
            refused(fleet_id, {:error, %Ash.Error.Forbidden{}})

          %{commits: :unreadable} ->
            Refusal.answer(503, "code_unavailable")

          history ->
            ok(%{
              commits: Enum.map(history.commits, &history_commit(&1, fleet_id, repository)),
              head: history.head,
              next: if(history.more?, do: %{from: history.head, page: history.page + 1})
            })
        end

      {:refused, status, code} ->
        Refusal.answer(status, code)
    end
  rescue
    NotFoundError -> Refusal.answer(404, "history_page_unknown")
  end

  def answer(:commit, %{"fleet_id" => fleet_id} = params, actor, _waiter) do
    case repository(fleet_id, params["project"]) do
      {:ok, repository} ->
        fleet_id
        |> WorkspacePage.commit(repository, params["commit"], actor)
        |> case do
          %{members_only?: true} -> refused(fleet_id, {:error, %Ash.Error.Forbidden{}})
          %{change: :unreadable} -> Refusal.answer(503, "code_unavailable")
          %{change: :not_found} -> Refusal.answer(404, "commit_unknown")
          commit -> ok(commit_body(commit))
        end

      {:refused, status, code} ->
        Refusal.answer(status, code)
    end
  rescue
    NotFoundError -> Refusal.answer(404, "commit_unknown")
  end

  defp ok(body), do: {200, body, nil}

  defp repository(fleet_id, project) do
    case Fleets.get_fleet(fleet_id, actor: %System{}) do
      {:ok, %{}} ->
        case Code.repository(fleet_id, project) do
          {:ok, repository} when is_binary(repository) -> {:ok, repository}
          {:ok, nil} -> {:refused, 404, "project_unknown"}
          {:error, _error} -> {:refused, 503, "code_catching_up"}
        end

      {:ok, nil} ->
        {:refused, 404, "fleet_unknown"}
    end
  end

  defp history_commit(commit, fleet_id, repository) do
    %{
      commit: commit.hash,
      commit_url: WorkspacePage.commit_url(fleet_id, repository, commit.hash),
      subject: commit.subject,
      author: commit.author,
      written_at: commit.at,
      sent_by: sent_by(commit.sent),
      cited_by: Enum.map(commit.citing, &Map.take(&1, [:id, :type, :title]))
    }
  end

  defp commit_body(%{change: change} = commit) do
    %{
      commit: commit.hash,
      commit_url: commit.url,
      subject: change.subject,
      message: change.body,
      author: change.author,
      written_at: change.at,
      parents: Enum.map(change.parents, & &1.hash),
      sent_by: sent_by(commit.sent),
      files:
        for file <- change.files do
          %{
            path: file.path,
            old_path: file.old_path,
            status: file.status,
            additions: file.additions,
            deletions: file.deletions,
            binary: file.binary?,
            patch: file.patch,
            patch_truncated: file.cut?
          }
        end,
      files_truncated: change.files_cut?,
      files_url: Endpoint.url() <> commit.files_link,
      cited_by:
        for work <- commit.citing do
          %{
            id: work.id,
            type: work.type,
            title: work.title,
            archived: work.archived?,
            notebook_ref: work.notebook_ref,
            result_ref: work.result_ref
          }
        end
    }
  end

  defp sent_by(nil), do: nil

  defp sent_by(sent),
    do: %{token_id: sent.token_id, agent_name: sent.agent, ref: sent.ref, pushed_at: sent.at}

  defp refused(fleet_id, {:error, %Ash.Error.Forbidden{}}),
    do: Refusal.holders_only(fleet_id, "code_not_holder")

  defp refused(fleet_id, {:error, error}) do
    Keyfleet.Code.RecordsDownError.report(
      "The changes sent to the code of #{fleet_id} could not be read: " <>
        inspect(error.__struct__)
    )

    Refusal.answer(503, "code_catching_up")
  end
end
