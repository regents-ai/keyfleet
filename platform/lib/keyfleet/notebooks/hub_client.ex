defmodule Keyfleet.Notebooks.HubClient do
  @moduledoc """
  What this site asks of a fleet's hub, as the hub's provisioner
  (`kf_provisioner_<fleet id>`, the one super admin each hub names). Every
  call is made once: the job that makes it retries the whole job.

  Each answer is `{:ok, data}` or `{:error, reason}`. Adding someone already
  there, and removing or reactivating someone who isn't, answer `{:ok, nil}`.
  """

  alias Keyfleet.Notebooks
  alias Keyfleet.Notebooks.Pass

  # The most the hub answers in one page of a list.
  @page_size 500

  @doc "The hub user this site manages the fleet's hub as."
  def provisioner(fleet_id), do: "kf_provisioner_#{fleet_id}"

  @doc "Every project in the hub."
  def projects(fleet_id), do: pages(fleet_id, "/api/v1/projects")

  @doc "Makes a project the provisioner owns."
  def create_project(fleet_id, name) do
    fleet_id
    |> request(:post, "/api/v1/projects", json: %{name: name, description: ""})
    |> answer([201])
  end

  @doc "The project's members, each named by `user_id` or, when it was added by its address, `email`."
  def members(fleet_id, project_id),
    do:
      fleet_id
      |> request(:get, "/api/v1/projects/#{segment(project_id)}/members")
      |> answer([200])

  @doc "Makes `subject` an editor of the project, by the address the hub knows them by."
  def add_editor(fleet_id, project_id, subject) do
    fleet_id
    |> request(:post, "/api/v1/projects/#{segment(project_id)}/members",
      json: %{email: Notebooks.email(subject), role: "editor"}
    )
    |> answer([201], [409])
  end

  @doc "Removes a member, named by `user_id` or, for one added by its address, by `email`."
  def remove_member(fleet_id, project_id, member) do
    fleet_id
    |> request(:delete, "/api/v1/projects/#{segment(project_id)}/members/#{segment(member)}")
    |> answer([200], [404])
  end

  @doc "Every user who has signed in to the hub, with `suspended_at`."
  def users(fleet_id), do: pages(fleet_id, "/api/v1/admin/users")

  @doc "Stops `user_id` signing in to the hub at all."
  def suspend(fleet_id, user_id) do
    fleet_id
    |> request(:put, "/api/v1/admin/users/#{segment(user_id)}/suspension")
    |> answer([200], [404])
  end

  @doc "Lets a suspended `user_id` sign in to the hub again."
  def reactivate(fleet_id, user_id) do
    fleet_id
    |> request(:delete, "/api/v1/admin/users/#{segment(user_id)}/suspension")
    |> answer([200], [404])
  end

  @doc "Every notebook session running in the project, each with the `user_id` who started it."
  def sessions(fleet_id, project_id),
    do: pages(fleet_id, "/api/v1/projects/#{segment(project_id)}/sessions")

  @doc "Stops a running notebook session, whoever started it."
  def stop_session(fleet_id, project_id, notebook_id, session_id) do
    fleet_id
    |> request(
      :delete,
      "/api/v1/projects/#{segment(project_id)}/notebooks/#{segment(notebook_id)}/sessions/#{segment(session_id)}"
    )
    |> answer([200], [404])
  end

  defp request(fleet_id, method, path, options \\ []) do
    {:ok, address} = Notebooks.hub_address(fleet_id)

    Req.request(
      [
        method: method,
        base_url: address,
        url: path,
        headers: [{"x-keyfleet-assertion", Pass.mint(fleet_id, provisioner(fleet_id))}],
        retry: false,
        redirect: false,
        receive_timeout: Notebooks.config()[:hub_timeout_ms]
      ] ++ options
    )
  end

  # Every item of a list the hub answers a page at a time, in the hub's order.
  defp pages(fleet_id, path, cursor \\ nil, earlier \\ []) do
    params = [limit: @page_size] ++ if(cursor, do: [cursor: cursor], else: [])

    case fleet_id |> request(:get, path, params: params) |> answer([200]) do
      {:ok, %{"items" => items, "next_cursor" => nil}} ->
        {:ok, earlier ++ items}

      {:ok, %{"items" => items, "next_cursor" => next}} when is_binary(next) ->
        pages(fleet_id, path, next, earlier ++ items)

      {:ok, other} ->
        {:error, {:unexpected_page, other}}

      error ->
        error
    end
  end

  defp answer(response, ok, settled \\ []) do
    case response do
      {:ok, %Req.Response{status: status, body: body}} ->
        cond do
          status in ok -> {:ok, data(body)}
          status in settled -> {:ok, nil}
          true -> {:error, {:hub_status, status}}
        end

      {:error, error} ->
        {:error, error}
    end
  end

  defp data(%{"data" => data}), do: data
  defp data(_body), do: nil

  defp segment(value), do: URI.encode(value, &URI.char_unreserved?/1)
end
