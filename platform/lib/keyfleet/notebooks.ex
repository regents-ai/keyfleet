defmodule Keyfleet.Notebooks do
  @moduledoc """
  Each fleet's private notebook hub, opened only through this site.

  A fleet's hub answers at its own host, `<fleet id, hyphenated>.<host_suffix>`,
  and every request there reaches this site first (`KeyfleetWeb.Plugs.NotebookGateway`).
  Whoever holds one of the fleet's keys, or an agent with an active shard of
  one, gets in; the hub knows them only by their account here:
  `u_<account id>` for a person and `a_<agent profile id>` for an agent, never
  by a wallet. Each request carries a short pass this site signs
  (`Keyfleet.Notebooks.Pass`).

  A person opens the notebooks from the fleet's workspace, which hands their
  browser a link that works once (`open/3`); the notebook sign-in it sets ends
  when their Keyfleet sign-in does. When a key changes hands, a job
  brings the fleet's hub in step (`Keyfleet.Notebooks.Roster`) and ends the
  open notebook connections of whoever lost their key (`end_access/2`).
  """
  use Ash.Domain

  require Ash.Query

  alias Keyfleet.AccessCache
  alias Keyfleet.Accounts.SessionAuthority
  alias Keyfleet.Actors.{Agent, Human, System}
  alias Keyfleet.Graph.Checks.KeyActor
  alias Keyfleet.Notebooks.{Handoff, Hub}

  resources do
    resource Keyfleet.Notebooks.Hub do
      define :record_hub, action: :record, args: [:fleet_id, :project_id]
      define :get_hub, action: :read, get_by: [:fleet_id], not_found_error?: false
    end

    resource Keyfleet.Notebooks.Handoff
  end

  @email_domain "identity.keyfleet.invalid"

  @doc "The notebook settings: `config :keyfleet, :notebooks`."
  def config, do: Application.fetch_env!(:keyfleet, :notebooks)

  @doc "The private address of the fleet's hub, as `{:ok, url}`, or `:error` when it has none."
  def hub_address(fleet_id), do: Map.fetch(config()[:fleets], fleet_id)

  @doc "Whether the fleet has a notebook hub."
  def hub?(fleet_id), do: Map.has_key?(config()[:fleets], fleet_id)

  @doc "The fleets that have a notebook hub."
  def hub_fleet_ids, do: Map.keys(config()[:fleets])

  @doc "The host the fleet's notebooks answer at."
  def host(fleet_id), do: String.replace(fleet_id, "_", "-") <> "." <> config()[:host_suffix]

  @doc "The fleet whose notebooks answer at `host`, as `{:ok, fleet_id}`, or `:error`."
  def fleet_for_host(host) do
    with [label, suffix] <- String.split(host, ".", parts: 2),
         true <- suffix == config()[:host_suffix],
         fleet_id = String.replace(label, "-", "_"),
         true <- host(fleet_id) == host and hub?(fleet_id) do
      {:ok, fleet_id}
    else
      _ -> :error
    end
  end

  @doc "Whether `host` is one of the fleets' notebook hosts, configured or not."
  def notebook_host?(host), do: String.ends_with?(host, "." <> config()[:host_suffix])

  @doc "The address of the fleet's notebooks, at `path`."
  def url(fleet_id, path, query \\ nil) do
    %URI{
      scheme: "https",
      host: host(fleet_id),
      port: config()[:public_port],
      path: path,
      query: query
    }
    |> URI.to_string()
  end

  @doc "How the hubs know a person: by their account here."
  def subject(%Human{human_account_id: id}) when is_integer(id), do: "u_#{id}"

  @doc "How the hubs know an agent: by its profile here."
  def agent_subject(profile_id), do: "a_#{profile_id}"

  @doc "The address a hub keeps for `subject`. It receives no mail."
  def email(subject), do: subject <> "@" <> @email_domain

  @doc "The subject an address the hubs keep stands for, or nil when it is none of ours."
  def subject_of_email(email) do
    case String.split(email, "@") do
      [subject, @email_domain] -> if managed_subject?(subject), do: subject
      _other -> nil
    end
  end

  @doc "Whether this site manages the hub user `subject`: a person's or an agent's."
  def managed_subject?("u_" <> id), do: id != ""
  def managed_subject?("a_" <> id), do: id != ""
  def managed_subject?(_subject), do: false

  @doc """
  Whether `actor` may open the fleet's notebooks now: `{:ok, true}` when it
  holds one of the fleet's keys or, for an agent, an active shard of one,
  `{:ok, false}` when it holds neither, and `{:error, error}` when the fleet's
  key ownership can't be read right now.

  The answer is the workspace's own (`KeyActor.member/3`): who may read the
  workspace may open its notebooks.
  """
  def member?(actor, fleet_id) do
    KeyActor.member(actor, fleet_id, Application.fetch_env!(:keyfleet, :graph)[:check_timeout])
  end

  @doc """
  Opens the fleet's notebooks for a person signed in by the session `lineage`:
  `{:ok, url}`, the fleet's notebook address with a link that works once, for
  `handoff_ttl_seconds`; `{:error, :signed_out}` when that sign-in is no longer
  current; `{:error, :not_holder}` when they hold none of the fleet's keys;
  `{:error, :no_hub}` when the fleet has no notebooks; or `{:error, error}`
  when ownership can't be read right now.
  """
  def open(%Human{human_account_id: account_id} = actor, lineage, fleet_id) do
    with true <- hub?(fleet_id) || {:error, :no_hub},
         session_id when is_binary(session_id) <-
           SessionAuthority.current_id(lineage, account_id) || {:error, :signed_out},
         {:ok, true} <- member?(actor, fleet_id) do
      code = Base.url_encode64(:crypto.strong_rand_bytes(32), padding: false)
      expires_at = DateTime.add(DateTime.utc_now(), config()[:handoff_ttl_seconds], :second)

      Handoff
      |> Ash.Changeset.for_create(
        :issue,
        %{
          code_hash: hash(code),
          fleet_id: fleet_id,
          human_account_id: account_id,
          session_authority_id: session_id,
          expires_at: expires_at
        },
        actor: %System{}
      )
      |> Ash.create!()

      {:ok, url(fleet_id, "/_keyfleet/enter", URI.encode_query(code: code))}
    else
      {:ok, false} -> {:error, :not_holder}
      {:error, error} -> {:error, error}
    end
  end

  @doc """
  Spends a link `open/3` made for the fleet: `{:ok, {human_account_id,
  session_authority_id}}` the first time, within its time, and `:error` after that, for another fleet, or
  for a code it never made. One statement checks and spends it, so two
  requests with the same code can't both get in.
  """
  def redeem(fleet_id, code) when is_binary(code) do
    Handoff
    |> Ash.Query.for_read(:redeemable, %{code_hash: hash(code), fleet_id: fleet_id},
      actor: %System{}
    )
    |> Ash.bulk_update!(:redeem, %{},
      actor: %System{},
      strategy: :atomic,
      return_records?: true,
      notify?: false
    )
    |> case do
      %Ash.BulkResult{records: [%Handoff{} = handoff]} ->
        {:ok, {handoff.human_account_id, handoff.session_authority_id}}

      %Ash.BulkResult{records: []} ->
        :error
    end
  end

  def redeem(_fleet_id, _code), do: :error

  defp hash(code), do: :crypto.hash(:sha256, code)

  @doc """
  The person a notebook sign-in names, while the Keyfleet sign-in it was opened
  under is still current: `{:ok, actor, topic}`, where `topic` is where that
  sign-in's ending is announced, or `:signed_out` once they signed out there,
  switched account or it ran out.
  """
  def person(session_authority_id, account_id) do
    case SessionAuthority.signed_in(session_authority_id, account_id) do
      nil -> :signed_out
      {account, topic} -> {:ok, Human.for_account(account), topic}
    end
  end

  @doc "The agent a signed request names, with the subject the hubs know it by, or nil without a profile."
  def agent(%Agent{} = actor) do
    case Keyfleet.Agents.get_my_profile(actor: actor) do
      {:ok, nil} -> {:ok, nil}
      {:ok, profile} -> {:ok, agent_subject(profile.id)}
      {:error, error} -> {:error, error}
    end
  end

  @doc """
  Ends `subject`'s access to the fleet's notebooks on every node now: its open
  notebook connections close and its next request is checked afresh.
  """
  def end_access(fleet_id, subject) do
    AccessCache.end_access(:notebooks, fleet_id, subject)

    Phoenix.PubSub.broadcast(
      Keyfleet.PubSub,
      access_topic(fleet_id, subject),
      :notebook_access_ended
    )
  end

  @doc """
  Where one subject's open notebook connections to a fleet are registered:
  each connection subscribes here, and `end_access/2` closes them all.
  """
  def access_topic(fleet_id, subject), do: "notebook_access:#{fleet_id}:#{subject}"

  @doc "The project the fleet's key holders work in, once this site has set the hub up."
  def project_id(fleet_id) do
    case get_hub(fleet_id, actor: %System{}) do
      {:ok, %Hub{project_id: project_id}} -> {:ok, project_id}
      {:ok, nil} -> {:ok, nil}
      {:error, error} -> {:error, error}
    end
  end
end
