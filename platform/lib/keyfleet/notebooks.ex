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

  A person opens the notebooks from the fleet's workspace, whose page sends
  the notebook host a code that works once (`open/4`); the notebook sign-in it sets ends
  when their Keyfleet sign-in does. When a key changes hands, a job
  brings the fleet's hub in step (`Keyfleet.Notebooks.Roster`) and ends the
  open notebook connections of whoever lost their key (`end_access/2`).
  """
  use Ash.Domain

  alias Keyfleet.AccessCache
  alias Keyfleet.Accounts.SessionAuthority
  alias Keyfleet.Actors.{Agent, Human, System}
  alias Keyfleet.Graph.Checks.KeyActor
  alias Keyfleet.Notebooks.{Handoff, Hub, HubClient, HubSilentError, Roster}

  resources do
    resource Keyfleet.Notebooks.Hub do
      define :record_hub, action: :record, args: [:fleet_id, :project_id]
      define :get_hub, action: :read, get_by: [:fleet_id], not_found_error?: false
    end

    resource Keyfleet.Notebooks.Handoff

    resource Keyfleet.Notebooks.FileMaker do
      define :record_file_maker, action: :record, args: [:fleet_id, :notebook_id, :path, :maker]

      define :file_makers_at_or_under,
        action: :at_or_under,
        args: [:fleet_id, :notebook_id, :path]
    end

    resource Keyfleet.Notebooks.SavedOutput do
      define :keep_saved_output,
        action: :keep,
        args: [:fleet_id, :notebook_id, :source_id, :saved_at, :page]

      define :saved_output,
        action: :at,
        args: [:fleet_id, :notebook_id, :source_id, :saved_at],
        not_found_error?: false

      define :saved_outputs, action: :of_sources, args: [:fleet_id, :source_ids]
      define :remove_saved_output, action: :remove
    end
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

  # The hub's own id shapes (marimohub c2a3303, packages/core/src/ids.ts): a
  # saved page comes from a notebook version or from a background run. And
  # when a saved page was made, in milliseconds since 1970.
  @project_id ~r/\Aproj-[0-9a-z]{16}\z/
  @notebook_id ~r/\Anb-[0-9a-z]{16}\z/
  @source_id ~r/\A(ver_[0-9A-Z]{26}|run_[0-9A-HJKMNP-TV-Z]{26})\z/
  @saved_at ~r/\A[1-9][0-9]{0,15}\z/

  @doc """
  A saved notebook output's address: one saved page of a notebook, on the
  fleet's notebook host,
  `https://<fleet host>/results/<notebook id>/<source id>/<saved at>`. The
  source is the notebook version (`ver_…`) a session saved the page with, or
  the background run (`run_…`) that made it; `saved at` is when the hub made
  that page, in milliseconds since 1970. A hub makes a new page for a version
  each time that version's code runs again, so the time names exactly one
  page. The address shows Keyfleet's own copy of that page
  (`Keyfleet.Notebooks.SavedOutput`) until a member removes it, whatever the
  hub keeps. Only the fleet's members open it.
  """
  def result_url(fleet_id, notebook_id, source_id, saved_at),
    do: url(fleet_id, result_path(notebook_id, source_id, saved_at))

  @doc "The path of a saved output on its fleet's notebook host."
  def result_path(notebook_id, source_id, saved_at),
    do: "/results/#{notebook_id}/#{source_id}/#{saved_at}"

  @doc """
  The saved output a path names, as `{:ok, {notebook_id, source_id, saved_at}}`,
  or `:error`. Only the address `result_path/3` spells is one.
  """
  def result(path) do
    with ["", "results", notebook_id, source_id, saved_at] <- String.split(path, "/"),
         true <-
           Regex.match?(@notebook_id, notebook_id) and Regex.match?(@source_id, source_id) and
             Regex.match?(@saved_at, saved_at) do
      {:ok, {notebook_id, source_id, String.to_integer(saved_at)}}
    else
      _ -> :error
    end
  end

  @doc """
  When a hub made a saved page, from its `X-Marimohub-Captured-At` time, as
  `{:ok, milliseconds since 1970}`, or `:error`.
  """
  def saved_at(captured_at) do
    case DateTime.from_iso8601(captured_at) do
      {:ok, at, _offset} -> {:ok, DateTime.to_unix(at, :millisecond)}
      {:error, _reason} -> :error
    end
  end

  @doc "The path of one notebook on its fleet's notebook host, where it opens to edit."
  def notebook_path(project_id, notebook_id),
    do: "/projects/#{project_id}/notebooks/#{notebook_id}"

  @doc """
  The address of one notebook on its fleet's notebook host, as a task cites
  it in `notebook_ref`.
  """
  def notebook_url(fleet_id, project_id, notebook_id),
    do: url(fleet_id, notebook_path(project_id, notebook_id))

  @doc """
  Where a link that opens the notebooks may land: their start page, one
  notebook (`notebook_path/2`) or a saved output.
  """
  def destination?("/"), do: true

  def destination?(path) when is_binary(path),
    do: notebook?(path) or result(path) != :error

  def destination?(_path), do: false

  @doc "Whether `path` is one notebook's path on its fleet's notebook host (`notebook_path/2`)."
  def notebook?(path) do
    case String.split(path, "/") do
      ["", "projects", project_id, "notebooks", notebook_id] ->
        Regex.match?(@project_id, project_id) and Regex.match?(@notebook_id, notebook_id)

      _other ->
        false
    end
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
  Whether `actor` is one of the fleet's members now (`member?/2`), and
  whether a vote of the fleet has restricted the edits of the Key it is in
  the fleet as: `{:ok, %{restricted?: boolean}}`, `{:ok, nil}` when it is
  not a member, or `{:error, error}` when either can't be read right now. A
  restricted Key opens and reads the notebooks but changes nothing in them.
  """
  def membership(actor, fleet_id) do
    within = Application.fetch_env!(:keyfleet, :graph)[:check_timeout]

    with {:ok, %{} = member} <- KeyActor.membership(actor, fleet_id, within),
         do: {:ok, Map.take(member, [:restricted?])}
  end

  @doc """
  Lets `actor`, known to the hubs as `subject`, into the fleet's notebooks
  now: `{:ok, %{project_id:, restricted?:}}` once it is one of the fleet's
  members (`membership/2`, which says whether its Key's edits are
  restricted) and an editor of the fleet's project in the hub, or
  `{:error, reason}`: `:not_holder`, `:catching_up` while key ownership can't
  be read, `:setting_up` while the hub has no project yet (a job is booked
  to make it), or `:unavailable` when the hub didn't answer. Someone who lost
  a key and holds one again was suspended in the hub, and is let back in.
  """
  def admit(actor, fleet_id, subject) do
    with {:holder, {:ok, %{restricted?: restricted?}}} <-
           {:holder, membership(actor, fleet_id)},
         {:project, {:ok, project_id}} when is_binary(project_id) <-
           {:project, project_id(fleet_id)},
         {:hub, :ok} <- {:hub, make_editor(fleet_id, project_id, subject)} do
      access = %{project_id: project_id, restricted?: restricted?}
      AccessCache.admit(:notebooks, fleet_id, subject, access, config()[:access_ttl_ms])
      {:ok, access}
    else
      {:holder, {:ok, nil}} ->
        {:error, :not_holder}

      {:holder, {:error, _error}} ->
        {:error, :catching_up}

      {:project, {:ok, nil}} ->
        Oban.insert!(Roster.new(%{fleet_id: fleet_id}))
        {:error, :setting_up}

      {:project, {:error, _error}} ->
        {:error, :unavailable}

      {:hub, {:error, reason}} ->
        HubSilentError.report(
          "The notebook hub of #{fleet_id} did not make a holder an editor: #{inspect(reason)}"
        )

        {:error, :unavailable}
    end
  end

  defp make_editor(fleet_id, project_id, subject) do
    with {:ok, _added} <- HubClient.add_editor(fleet_id, project_id, subject),
         {:ok, _reactivated} <- HubClient.reactivate(fleet_id, subject) do
      :ok
    end
  end

  @doc """
  Whether the fleet's notebooks have room for a session of `notebook_id` now,
  whoever starts it: `{:ok, true}` while fewer than `max_sessions` are open in
  the fleet's project, or when one of them is already that notebook's, which
  starting it again joins; `{:ok, false}` when they are full; or
  `{:error, :unavailable}` when the open sessions can't be read. A background
  run is the hub's job, not a session, so it takes no room. Two sessions
  started at the same moment may both find the last place.
  """
  def session_room?(fleet_id, notebook_id) do
    with {:project, {:ok, project_id}} when is_binary(project_id) <-
           {:project, project_id(fleet_id)},
         {:hub, {:ok, sessions}} <- {:hub, HubClient.sessions(fleet_id, project_id)} do
      {:ok,
       length(sessions) < config()[:max_sessions] or
         Enum.any?(sessions, &(&1["notebook_id"] == notebook_id))}
    else
      {:project, _none} ->
        {:error, :unavailable}

      {:hub, {:error, reason}} ->
        HubSilentError.report(
          "The notebook hub of #{fleet_id} did not list its open sessions: #{inspect(reason)}"
        )

        {:error, :unavailable}
    end
  end

  @doc """
  Opens the fleet's notebooks for a person signed in by the session `lineage`:
  `{:ok, %{action: url, code: code, to: to}}`, the form Keyfleet's page sends
  to the fleet's notebook address, with a code that works once, for
  `handoff_ttl_seconds`, landing on `to` (`destination?/1`: the start page,
  one notebook or a saved output); `{:error, :no_hub}` when the fleet has no notebooks;
  `{:error, :invalid_destination}` for anywhere else to land;
  `{:error, :signed_out}` when that sign-in is no longer current;
  `{:error, :not_holder}` when they hold none of the fleet's keys; or `{:error, error}`
  when ownership can't be read right now.
  """
  def open(%Human{human_account_id: account_id} = actor, lineage, fleet_id, to \\ "/") do
    with true <- hub?(fleet_id) || {:error, :no_hub},
         true <- destination?(to) || {:error, :invalid_destination},
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

      {:ok, %{action: url(fleet_id, "/_keyfleet/enter"), code: code, to: to}}
    else
      {:ok, false} -> {:error, :not_holder}
      {:error, error} -> {:error, error}
    end
  end

  @doc """
  Spends a code `open/4` made for the fleet: `{:ok, {human_account_id,
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
  under is still current: `{:ok, actor, topic, ends_at}`, where `topic` is
  where that sign-in's ending is announced and `ends_at` is when it runs out,
  or `:signed_out` once they signed out there, switched account or it ran out.
  """
  def person(session_authority_id, account_id) do
    case SessionAuthority.signed_in(session_authority_id, account_id) do
      nil -> :signed_out
      {account, topic, ends_at} -> {:ok, Human.for_account(account), topic, ends_at}
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
  Ends everyone's admission to the fleet's notebooks on every node now, so
  each one's next request is checked afresh (from `Keyfleet.Chain.Scanner`,
  when the fleet's Keys change).
  """
  def end_access(fleet_id), do: AccessCache.end_fleet(:notebooks, fleet_id)

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
