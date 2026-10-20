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

  @doc "The hub user this site manages the fleet's hub as."
  def provisioner(fleet_id), do: "kf_provisioner_#{fleet_id}"

  @doc "Every project in the hub."
  def projects(fleet_id), do: fleet_id |> request(:get, "/api/v1/projects") |> page()

  @doc """
  The project's 50 newest notebooks tagged `tag`, each with `id` and
  `title`, waiting `page_timeout_ms` at most, for a page that shows them.
  """
  def tagged_notebooks(fleet_id, project_id, tag) do
    fleet_id
    |> request(:get, "/api/v1/projects/#{segment(project_id)}/notebooks",
      params: [tag: tag, limit: 50],
      receive_timeout: Notebooks.config()[:page_timeout_ms]
    )
    |> page()
  end

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

  @doc """
  The project's sessions open now (starting, running or ending), newest
  first, each with `session_id`, `notebook_id`, `status` and `mode`.
  """
  def sessions(fleet_id, project_id),
    do:
      fleet_id
      |> request(:get, "/api/v1/projects/#{segment(project_id)}/sessions")
      |> page()

  @doc "Every user who has signed in to the hub, with `suspended_at`."
  def users(fleet_id), do: fleet_id |> request(:get, "/api/v1/admin/users") |> page()

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

  defp request(fleet_id, method, path, options \\ []) do
    {:ok, address} = Notebooks.hub_address(fleet_id)

    Req.request(
      Keyword.merge(
        [
          method: method,
          base_url: address,
          url: path,
          headers: [{"x-keyfleet-assertion", Pass.mint(fleet_id, provisioner(fleet_id))}],
          retry: false,
          redirect: false,
          receive_timeout: Notebooks.config()[:hub_timeout_ms]
        ],
        options
      )
    )
  end

  defp page(response) do
    case answer(response, [200]) do
      {:ok, %{"items" => items}} -> {:ok, items}
      {:ok, _other} -> {:error, :unexpected_page}
      error -> error
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
