defmodule KeyfleetWeb.AgentCodeController do
  @moduledoc """
  The changes sent lately to one project's repository, each with the address
  a workspace cites its commit by; its history; and one commit with what it
  changed, read as the commit page and the history page read them
  (`KeyfleetWeb.WorkspacePage`). Git itself reaches the code through
  `KeyfleetWeb.Plugs.CodeGateway`.
  """
  use KeyfleetWeb, :controller

  alias Keyfleet.Actors.System
  alias Keyfleet.{Code, Fleets, Projects}
  alias KeyfleetWeb.{Endpoint, NotFoundError, Refusal, WorkspacePage}

  def pushes(conn, %{"fleet_id" => fleet_id, "project" => project}) do
    with {:ok, %{}} <- Fleets.get_fleet(fleet_id, actor: %System{}),
         {:ok, pushes} <-
           Code.recent_pushes(fleet_id, project, actor: conn.assigns.agent_actor),
         {:project, {:ok, %{repository: repository}}} <-
           {:project, Projects.project(fleet_id, project, actor: conn.assigns.agent_actor)} do
      json(conn, %{
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
      {:ok, nil} -> Refusal.json(conn, 404, "fleet_unknown")
      {:project, {:ok, nil}} -> Refusal.json(conn, 404, "project_unknown")
      {:project, failed} -> refused(conn, fleet_id, failed)
      failed -> refused(conn, fleet_id, failed)
    end
  end

  def commits(conn, %{"fleet_id" => fleet_id, "project" => project} = params) do
    with {:ok, repository} <- repository(fleet_id, project) do
      fleet_id
      |> WorkspacePage.history(repository, params, conn.assigns.agent_actor)
      |> case do
        %{members_only?: true} ->
          refused(conn, fleet_id, {:error, %Ash.Error.Forbidden{}})

        %{commits: :unreadable} ->
          Refusal.json(conn, 503, "code_unavailable")

        history ->
          json(conn, %{
            commits: Enum.map(history.commits, &history_commit(&1, fleet_id, repository)),
            head: history.head,
            next: if(history.more?, do: %{from: history.head, page: history.page + 1})
          })
      end
    else
      {:refused, status, code} -> Refusal.json(conn, status, code)
    end
  rescue
    NotFoundError -> Refusal.json(conn, 404, "history_page_unknown")
  end

  def commit(conn, %{"fleet_id" => fleet_id, "project" => project, "commit" => hash}) do
    with {:ok, repository} <- repository(fleet_id, project) do
      fleet_id
      |> WorkspacePage.commit(repository, hash, conn.assigns.agent_actor)
      |> case do
        %{members_only?: true} -> refused(conn, fleet_id, {:error, %Ash.Error.Forbidden{}})
        %{change: :unreadable} -> Refusal.json(conn, 503, "code_unavailable")
        %{change: :not_found} -> Refusal.json(conn, 404, "commit_unknown")
        commit -> json(conn, commit_body(commit))
      end
    else
      {:refused, status, code} -> Refusal.json(conn, status, code)
    end
  rescue
    NotFoundError -> Refusal.json(conn, 404, "commit_unknown")
  end

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

  defp refused(conn, fleet_id, {:error, %Ash.Error.Forbidden{}}) do
    if Keyfleet.Chain.fresh?(fleet_id),
      do: Refusal.json(conn, 403, "code_not_holder"),
      else: Refusal.json(conn, 503, "ownership_refreshing")
  end

  defp refused(conn, fleet_id, {:error, error}) do
    Keyfleet.Code.RecordsDownError.report(
      "The changes sent to the code of #{fleet_id} could not be read: " <>
        inspect(error.__struct__)
    )

    Refusal.json(conn, 503, "code_catching_up")
  end
end
