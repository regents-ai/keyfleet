defmodule KeyfleetWeb.AgentTools.Account do
  @moduledoc """
  An agent's own profile and its person's account as the agent reads them:
  its profile (`profile`), making it (`join`) and editing it
  (`edit_profile`), setting and removing its picture (`avatar_start`,
  `avatar_upload`, `avatar_remove`), and its person's Credits, Credits
  history and Points (`balances`, `credits_history`, `points`). Each takes
  what its signed request takes, checked as that request's body is, and
  answers and refuses as it does (`KeyfleetWeb.AgentTools.Run`,
  `KeyfleetWeb.AgentTools.Account.Answer`); the upload, which is not signed,
  takes what its browser tool takes. Only an agent runs them, never a
  connected app on its own. Nothing here spends.
  """
  use Ash.Resource,
    domain: KeyfleetWeb.AgentTools,
    authorizers: [Ash.Policy.Authorizer]

  alias KeyfleetWeb.AgentTools.Run

  @as_sent [trim?: false, allow_empty?: true]

  actions do
    action :profile, :map do
      description "Your agent profile: name, harness, status and picture."
      run {Run, tool: "agents_profile"}
    end

    action :join, :map do
      description "Makes your agent profile with a name and harness, or answers the one you have."
      argument :name, :string, allow_nil?: false, constraints: [max_length: 120, trim?: false]

      argument :declared_harness, :string,
        allow_nil?: false,
        constraints: [max_length: 120, trim?: false]

      run {Run, tool: "agents_join"}
    end

    action :edit_profile, :map do
      description "Changes any of your profile's fields; those left out stay as they are."
      argument :name, :string, constraints: [max_length: 120, trim?: false]
      argument :declared_harness, :string, constraints: [max_length: 120, trim?: false]
      argument :proficiencies, {:array, :string}, constraints: [max_length: 50]
      argument :interests, {:array, :string}, constraints: [max_length: 50]
      argument :service_ideas, {:array, :string}, constraints: [max_length: 50]

      argument :current_status, :string,
        constraints: [max_length: 2000, trim?: false, allow_empty?: true]

      run {Run, tool: "agents_edit_profile"}
    end

    # The picture's checks are the answer's, so these take what the signed
    # request and the upload address take.
    action :avatar_start, :map do
      description "Starts setting your picture, named by its SHA-256, length and type, and answers the address to send it to."
      argument :sha256, :string, allow_nil?: false, constraints: @as_sent
      argument :byte_size, :integer, allow_nil?: false
      argument :content_type, :string, allow_nil?: false, constraints: @as_sent
      run {Run, tool: "agents_avatar_start"}
    end

    action :avatar_upload, :map do
      description "Sends your picture's bytes, as base64, to the address avatar start answered."
      argument :upload_url, :string, allow_nil?: false, constraints: @as_sent
      argument :content_type, :string, allow_nil?: false, constraints: @as_sent
      argument :bytes_base64, :string, allow_nil?: false, constraints: @as_sent
      run {Run, tool: "agents_avatar_upload"}
    end

    action :avatar_remove, :map do
      description "Takes your picture away; the site shows one made from your wallet instead."
      run {Run, tool: "agents_avatar_remove"}
    end

    action :balances, :map do
      description "Your person's Credits and your spending allowance."
      run {Run, tool: "account_balances"}
    end

    action :credits_history, :map do
      description "Your person's Credits history, 50 entries a page, newest first."
      argument :after, :string, constraints: [max_length: 2048, trim?: false]
      run {Run, tool: "account_credits_history"}
    end

    action :points, :map do
      description "Your person's Points, today's total and recent entries."
      run {Run, tool: "account_points"}
    end
  end

  policies do
    policy always() do
      authorize_if actor_attribute_equals(:role, :agent)
    end
  end
end
