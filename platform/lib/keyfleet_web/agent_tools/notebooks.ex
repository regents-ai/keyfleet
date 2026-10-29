defmodule KeyfleetWeb.AgentTools.Notebooks do
  @moduledoc """
  A fleet's notebooks as an agent uses them: listing them (`list`), starting
  a run and reading it (`run`, `result`), making one (`create`), its files
  (`files`, `read_file`, `add_file`, `write_file`), locking it (`lock`) and
  the project's daily copies (`copies`, `restore`). Each takes what its
  signed request takes, checked as that request's body is, and answers and
  refuses as it does (`KeyfleetWeb.AgentTools.Run`,
  `KeyfleetWeb.AgentTools.Notebooks.Answer`). Only an agent runs them, never
  a connected app on its own; the notebook host lets it in as it lets in any
  agent.
  """
  use Ash.Resource,
    domain: KeyfleetWeb.AgentTools,
    authorizers: [Ash.Policy.Authorizer]

  alias KeyfleetWeb.AgentTools.Run

  @fleet [max_length: 63, trim?: false]
  @project [match: ~r/\A[a-z0-9]+(-[a-z0-9]+)*\z/, max_length: 32]
  @notebook [min_length: 19, max_length: 19, trim?: false]
  @path [max_length: 512, trim?: false]
  @once [max_length: 128, trim?: false]

  actions do
    action :list, :map do
      description "A project's notebooks, each with the last run an agent started there."
      argument :fleet_id, :string, allow_nil?: false, constraints: @fleet
      argument :project, :string, allow_nil?: false, constraints: @project
      run {Run, tool: "notebooks_list"}
    end

    action :run, :map do
      description "Starts a background run of a notebook's saved code, once for each key."
      argument :fleet_id, :string, allow_nil?: false, constraints: @fleet
      argument :project, :string, allow_nil?: false, constraints: @project
      argument :notebook_id, :string, allow_nil?: false, constraints: @notebook
      argument :idempotency_key, :string, allow_nil?: false, constraints: @once
      run {Run, tool: "notebooks_run"}
    end

    action :result, :map do
      description "A notebook run, and once it has finished, its saved result's address."
      argument :fleet_id, :string, allow_nil?: false, constraints: @fleet
      argument :project, :string, allow_nil?: false, constraints: @project
      argument :notebook_id, :string, allow_nil?: false, constraints: @notebook

      argument :run_id, :string,
        allow_nil?: false,
        constraints: [min_length: 30, max_length: 30, trim?: false]

      run {Run, tool: "notebooks_result"}
    end

    action :create, :map do
      description "Makes a notebook in a project, once for each key."
      argument :fleet_id, :string, allow_nil?: false, constraints: @fleet
      argument :project, :string, allow_nil?: false, constraints: @project
      argument :title, :string, allow_nil?: false, constraints: [max_length: 200, trim?: false]
      argument :code, :string, allow_nil?: false, constraints: [max_length: 20_480, trim?: false]
      argument :description, :string, constraints: [max_length: 1000, trim?: false]
      argument :goal, :string, constraints: [match: ~r/\Agoal#[1-9][0-9]{0,9}\z/]
      argument :folder, :string, constraints: [match: ~r/\A[A-Za-z0-9][A-Za-z0-9._-]{0,63}\z/]
      argument :idempotency_key, :string, allow_nil?: false, constraints: @once
      run {Run, tool: "notebooks_create"}
    end

    action :files, :map do
      description "A notebook's files in one folder, a page at a time."
      argument :fleet_id, :string, allow_nil?: false, constraints: @fleet
      argument :project, :string, allow_nil?: false, constraints: @project
      argument :notebook_id, :string, allow_nil?: false, constraints: @notebook
      argument :path, :string, constraints: @path
      argument :cursor, :string, constraints: @path
      run {Run, tool: "notebooks_files"}
    end

    action :read_file, :map do
      description "One of a notebook's files, whole."
      argument :fleet_id, :string, allow_nil?: false, constraints: @fleet
      argument :project, :string, allow_nil?: false, constraints: @project
      argument :notebook_id, :string, allow_nil?: false, constraints: @notebook
      argument :path, :string, allow_nil?: false, constraints: @path
      run {Run, tool: "notebooks_read_file"}
    end

    action :add_file, :map do
      description "Adds a new file to a notebook."
      argument :fleet_id, :string, allow_nil?: false, constraints: @fleet
      argument :project, :string, allow_nil?: false, constraints: @project
      argument :notebook_id, :string, allow_nil?: false, constraints: @notebook
      argument :path, :string, allow_nil?: false, constraints: @path

      argument :content, :string,
        allow_nil?: false,
        constraints: [max_length: 20_480, trim?: false, allow_empty?: true]

      run {Run, tool: "notebooks_add_file"}
    end

    action :write_file, :map do
      description "Writes a notebook's file whole, replacing what it held."
      argument :fleet_id, :string, allow_nil?: false, constraints: @fleet
      argument :project, :string, allow_nil?: false, constraints: @project
      argument :notebook_id, :string, allow_nil?: false, constraints: @notebook
      argument :path, :string, allow_nil?: false, constraints: @path

      argument :content, :string,
        allow_nil?: false,
        constraints: [max_length: 20_480, trim?: false, allow_empty?: true]

      run {Run, tool: "notebooks_write_file"}
    end

    action :lock, :map do
      description "Locks a notebook you made, or lets every member edit it again."
      argument :fleet_id, :string, allow_nil?: false, constraints: @fleet
      argument :project, :string, allow_nil?: false, constraints: @project
      argument :notebook_id, :string, allow_nil?: false, constraints: @notebook
      argument :locked, :boolean, allow_nil?: false
      run {Run, tool: "notebooks_lock"}
    end

    action :copies, :map do
      description "The daily copies of a project's notebooks."
      argument :fleet_id, :string, allow_nil?: false, constraints: @fleet
      argument :project, :string, allow_nil?: false, constraints: @project
      run {Run, tool: "notebooks_copies"}
    end

    action :restore, :map do
      description "Brings back a notebook from one of its daily copies."
      argument :fleet_id, :string, allow_nil?: false, constraints: @fleet
      argument :project, :string, allow_nil?: false, constraints: @project

      argument :copy_id, :string,
        allow_nil?: false,
        constraints: [min_length: 36, max_length: 36, trim?: false]

      run {Run, tool: "notebooks_restore"}
    end
  end

  policies do
    policy always() do
      authorize_if actor_attribute_equals(:role, :agent)
    end
  end
end
