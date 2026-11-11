defmodule Keyfleet.DatabaseConfig do
  @moduledoc false

  @cluster_id "dzx6qo6xqzvojpv5"
  @cluster_name "regents-platform-prod"
  @production_database_host "direct.dzx6qo6xqzvojpv5.flympg.net"
  # Superseded identities refused in production configuration: the legacy
  # platform application and the retired rehearsal cluster.
  @production_identities ["platform-phx", "regents-pg-test", "nvwq9ozp9ye03kl1"]
  @staging_hosts ["regents-staging-db.flycast", "regents-staging-db.internal"]
  # Staging can never reach production, so it refuses production's cluster, database
  # host and web application anywhere in a URL (host, database or credentials). These
  # terms are staging's alone: production runs as the Fly application regents-sh-web,
  # so refusing that name on the production role would refuse its own release commands.
  @staging_refusals [
    @cluster_id,
    @production_database_host,
    "regents-sh-web" | @production_identities
  ]
  @deployment_role_error ~s(KEYFLEET_DEPLOYMENT_ROLE must be set to "production" or "staging")
  @remote_target_error "remote database access requires cluster dzx6qo6xqzvojpv5 named regents-platform-prod"
  @lab_remote_error "the anvil lab runs on its local database only"
  @machine_error ~s(KEYFLEET_MACHINE must be "site" or "graph")

  # Every Regent site shares one production database, so each machine's pool is
  # as small as its work allows. The site machine serves pages and jobs from
  # five. The graph machine runs only the fleets' writers and projectors: a
  # projector holds one connection for each page of its fleet's log, about ten
  # statements, and a writer's ownership check takes one for each single-row
  # read, one read at a time. Neither holds a connection while it waits on the
  # other, so three serve all five fleets. A check that cannot get a connection
  # within its budget (the graph's :check_timeout) sends nothing.
  @site_pool_size 5
  @graph_pool_size 3

  def runtime_config!(environment, getenv \\ &System.get_env/1)

  def runtime_config!(:prod, getenv) do
    role = deployment_role!(getenv)
    pool_size = serving_pool_size!(getenv)
    getenv |> database_url!("DATABASE_POOLED_URL", role) |> serving(pool_size)
  end

  # Each anvil lab (docs/anvil-lab.md) keeps its own local database, named by
  # its chain's port, and never a remote one.
  def runtime_config!(:dev, getenv) do
    case {remote_target(getenv), getenv.("KEYFLEET_LAB")} do
      {:local, lab} ->
        [
          username: getenv.("USER"),
          password: nil,
          hostname: "127.0.0.1",
          port: 5432,
          database: local_database(lab),
          pool_size: 2
        ]

      # A developer's site against the production database takes the site
      # machine's pool.
      {:remote, lab} when lab in [nil, ""] ->
        getenv
        |> database_url!("DATABASE_POOLED_URL", :remote)
        |> Keyword.merge(pool_size: @site_pool_size)

      {:remote, _lab} ->
        raise @lab_remote_error
    end
  end

  # The test suite's repo is configured in config/test.exs.
  def runtime_config!(_environment, _getenv), do: nil

  @doc """
  The connection the site's listeners share (`Keyfleet.SharedChanges`): the
  repository's own login and address, one connection rather than a pool, named
  in pg_stat_activity.
  """
  def notifications_config(repo_config) do
    repo_config
    |> Keyword.drop([:name, :pool, :pool_size, :prepare, :parameters])
    |> connection_keys()
    |> Keyword.merge(auto_reconnect: true, parameters: [application_name: "keyfleet-listen"])
  end

  # Postgrex.Notifications takes connection keys, not the repository's URL.
  defp connection_keys(options) do
    case Keyword.pop(options, :url) do
      {nil, options} -> options
      {url, options} -> Keyword.merge(Ecto.Repo.Supervisor.parse_url(url), options)
    end
  end

  def release_config!(getenv \\ &System.get_env/1) do
    role = deployment_role!(getenv)
    if role == :production, do: require_production_target!(getenv)
    database_url!(getenv, "DATABASE_DIRECT_URL", role)
  end

  # The serving connection shares one database with every other site, so it names
  # itself in pg_stat_activity, keeps connection details out of its errors, and gives
  # up on a statement, a lock wait or an idle open transaction before it can stall
  # anyone else. Release commands connect with their own login and none of these
  # limits, through the migrator's own pool of two (`Ecto.Migrator.with_repo/3`).
  defp serving(options, pool_size) do
    Keyword.merge(options,
      pool_size: pool_size,
      show_sensitive_data_on_connection_error: false,
      parameters: [
        application_name: "keyfleet-web",
        statement_timeout: "15000",
        lock_timeout: "5000",
        idle_in_transaction_session_timeout: "15000"
      ]
    )
  end

  # No default and no fallback between roles: an unset or unrecognized role stops
  # the boot before any database URL is read.
  defp deployment_role!(getenv) do
    case getenv.("KEYFLEET_DEPLOYMENT_ROLE") do
      "production" -> :production
      "staging" -> :staging
      _unset_or_unknown -> raise @deployment_role_error
    end
  end

  # bin/site and bin/graph name the machine, as config/runtime.exs reads it.
  defp serving_pool_size!(getenv) do
    case getenv.("KEYFLEET_MACHINE") do
      "site" -> @site_pool_size
      "graph" -> @graph_pool_size
      _unset_or_unknown -> raise @machine_error
    end
  end

  # The hosts a venue admits (any, for a developer's remote target) and the terms
  # its URL may not name anywhere.
  defp venue(:production), do: {[@production_database_host], @production_identities}
  defp venue(:staging), do: {@staging_hosts, @staging_refusals}
  defp venue(:remote), do: {nil, @production_identities}

  defp database_url!(getenv, variable, venue) do
    {admitted_hosts, refused_terms} = venue(venue)

    with value when is_binary(value) and value != "" <- getenv.(variable),
         {:ok, %URI{scheme: scheme, host: host, path: "/" <> database, userinfo: userinfo} = uri}
         when scheme in ["postgres", "postgresql"] <- URI.new(value),
         true <- present?(host) and present?(database) and valid_userinfo?(userinfo),
         false <- refused_identity?(uri, refused_terms),
         {:ok, url, admitted_host} <- admit(value, uri, admitted_hosts),
         true <- fixed_endpoint?(uri) and valid_ecto_url?(value) do
      connection_options(url, admitted_host)
    else
      value when value in [nil, ""] -> raise "#{variable} is required"
      _ -> raise "#{variable} must be a valid PostgreSQL URL for the approved target"
    end
  end

  defp admit(value, %URI{host: host}, nil), do: {:ok, value, host}

  defp admit(_value, %URI{host: host} = uri, admitted_hosts) do
    admitted_host = String.downcase(host)

    if admitted_host in admitted_hosts,
      do: {:ok, URI.to_string(%{uri | host: admitted_host}), admitted_host},
      else: :error
  end

  defp valid_ecto_url?(value) do
    Ecto.Repo.Supervisor.parse_url(value)
    true
  rescue
    _error -> false
  end

  # Every host an allowlist admits is fixed by its hostname alone, so none may carry
  # a port other than PostgreSQL's or any query option: Ecto turns every URL query key
  # into an atom and merges parsed URL options after the explicit Repo configuration,
  # so even encoded or future aliases could otherwise weaken TLS, replace the endpoint,
  # or restore named prepares after this module's checks.
  defp fixed_endpoint?(%URI{host: host, port: port, query: query}) do
    not (fly_mpg_host?(host) or String.downcase(host) in @staging_hosts) or
      (port in [nil, 5432] and query in [nil, ""])
  end

  defp connection_options(url, host) do
    options = [url: url, socket_options: [:inet6]]
    if fly_mpg_host?(host), do: fly_mpg_options(host) ++ options, else: options
  end

  defp fly_mpg_options(host) do
    ssl = [
      verify: :verify_peer,
      cacerts: :public_key.cacerts_get(),
      server_name_indication: String.to_charlist(host),
      customize_hostname_check: [match_fun: :public_key.pkix_verify_hostname_match_fun(:https)]
    ]

    if host |> String.downcase() |> String.starts_with?("pgbouncer."),
      do: [prepare: :unnamed, ssl: ssl],
      else: [ssl: ssl]
  end

  defp fly_mpg_host?(host) do
    host = String.downcase(host)
    host != "flympg.net" and String.ends_with?(host, ".flympg.net")
  end

  defp remote_target(getenv) do
    cluster_id = getenv.("KEYFLEET_DATABASE_CLUSTER_ID")
    cluster_name = getenv.("KEYFLEET_DATABASE_CLUSTER_NAME")

    cond do
      production_identity?(getenv.("FLY_APP_NAME")) -> raise @remote_target_error
      is_nil(cluster_id) and is_nil(cluster_name) -> :local
      cluster_id == @cluster_id and cluster_name == @cluster_name -> :remote
      true -> raise @remote_target_error
    end
  end

  defp require_production_target!(getenv) do
    if getenv.("KEYFLEET_DATABASE_TARGET_MODE") == "production" and
         getenv.("KEYFLEET_DATABASE_CLUSTER_ID") == @cluster_id and
         getenv.("KEYFLEET_DATABASE_CLUSTER_NAME") == @cluster_name and
         not production_identity?(getenv.("FLY_APP_NAME")) do
      :ok
    else
      raise "database migration requires production mode for cluster dzx6qo6xqzvojpv5 named regents-platform-prod"
    end
  end

  defp valid_userinfo?(userinfo) when is_binary(userinfo),
    do: userinfo |> String.split(":", parts: 2) |> Enum.map(&present?/1) == [true, true]

  defp valid_userinfo?(_userinfo), do: false

  defp refused_identity?(%URI{} = uri, refused_terms) do
    Enum.any?([uri.host, uri.path, uri.userinfo], &names_any?(&1, refused_terms))
  end

  defp production_identity?(value), do: names_any?(value, @production_identities)

  defp names_any?(value, terms) when is_binary(value) do
    decoded = value |> decode() |> String.downcase()
    Enum.any?(terms, &String.contains?(decoded, &1))
  end

  defp names_any?(_value, _terms), do: false

  defp decode(value) do
    URI.decode(value)
  rescue
    _error -> value
  end

  defp local_database(lab) when lab in [nil, ""], do: "keyfleet_dev"
  defp local_database(lab), do: "keyfleet_lab_#{URI.parse(lab).port}_dev"

  defp present?(value), do: is_binary(value) and String.trim(value) != ""
end
