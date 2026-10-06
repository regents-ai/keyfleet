defmodule Keyfleet.MixProject do
  use Mix.Project

  # Shared Regent libraries, each pinned to one published commit. To move a pin,
  # change its ref and run `mix deps.update <name>`.
  @elixir_utils "https://github.com/regents-ai/elixir-utils.git"
  @elixir_utils_ref "467cba652f975f8ddbc169dac499d696bcb24248"
  @design_system "https://github.com/regents-ai/design-system.git"
  @design_system_ref "6bc26409835f76f99f91cf6e48bdebd18f1fe8eb"
  @regents "https://github.com/regents-ai/regents.git"
  @regents_ref "004307e65ffcf9cc9b3034d7cc2b015dcd45011b"

  def project do
    [
      app: :keyfleet,
      version: "0.1.0",
      elixir: "~> 1.15",
      elixirc_paths: elixirc_paths(Mix.env()),
      start_permanent: false,
      aliases: aliases(),
      deps: deps(),
      compilers: [:phoenix_live_view] ++ Mix.compilers(),
      listeners: [Phoenix.CodeReloader]
    ]
  end

  # Configuration for the OTP application.
  #
  # Type `mix help compile.app` for more information.
  def application do
    [
      mod: {Keyfleet.Application, []},
      extra_applications: [:logger, :runtime_tools]
    ]
  end

  def cli do
    [
      preferred_envs: [precommit: :test, "test.external": :test]
    ]
  end

  # Specifies which paths to compile per environment.
  defp elixirc_paths(:test), do: ["lib", "test/support"]
  defp elixirc_paths(_), do: ["lib"]

  # Specifies your project dependencies.
  #
  # Type `mix help deps` for examples and options.
  defp deps do
    [
      {:phoenix, "~> 1.8.9"},
      {:phoenix_live_reload, "~> 1.2", only: :dev},
      {:phoenix_live_view, "~> 1.2.6", override: true},
      {:ash, "~> 3.34 and >= 3.34.3"},
      {:ash_phoenix, "~> 2.3.25"},
      {:ash_postgres, "== 2.13.0"},
      {:oban, "~> 2.24"},
      # The notebook gateway's connection to a fleet hub's live notebook sockets.
      {:mint_web_socket, "~> 1.0"},
      # The code gateway streams git's request to the fleets' code store.
      {:mint, "~> 1.11"},
      {:ash_oban, "~> 0.9.0"},
      {:igniter, "== 0.8.4", only: [:dev, :test], runtime: false},
      {:mdex, "== 0.13.3"},
      {:regent_privy, git: @elixir_utils, ref: @elixir_utils_ref, sparse: "privy"},
      {:regent_identity, git: @regents, ref: @regents_ref, sparse: "identity"},
      {:regent_agents, git: @regents, ref: @regents_ref, sparse: "agents"},
      {:regent_ui, git: @design_system, ref: @design_system_ref, sparse: "regent_ui"},
      {:regent_agent_access, git: @elixir_utils, ref: @elixir_utils_ref, sparse: "agent_access"},
      {:siwa, git: @elixir_utils, ref: @elixir_utils_ref, sparse: "siwa/siwa-elixir/apps/siwa"},
      {:regent_format, git: @elixir_utils, ref: @elixir_utils_ref, sparse: "format"},
      {:regent_chain, git: @elixir_utils, ref: @elixir_utils_ref, sparse: "chain"},
      {:simple_sat, "~> 0.1"},
      {:sourceror, "~> 1.12", only: [:dev, :test], runtime: false},
      {:lazy_html, ">= 0.1.0", only: :test},
      {:esbuild, "~> 0.10", runtime: Mix.env() == :dev},
      {:telemetry_metrics, "~> 1.0"},
      {:telemetry_metrics_prometheus_core, "~> 1.2"},
      {:sentry, "~> 13.0"},
      {:jason, "~> 1.2"},
      {:yaml_elixir, "~> 2.12"},
      {:ex_keccak, "~> 0.7.8"},
      {:req, "== 0.7.4"},
      {:bandit, "~> 1.12.1"},
      {:credo, "~> 1.7", only: [:dev, :test], runtime: false},
      {:ex_slop, "~> 0.4", only: [:dev, :test], runtime: false},
      {:credo_ash,
       git: @elixir_utils,
       ref: @elixir_utils_ref,
       sparse: "credo_ash",
       only: [:dev, :test],
       runtime: false},
      {:sobelow, "~> 0.14", only: [:dev, :test], runtime: false}
    ]
  end

  # Aliases are shortcuts or tasks specific to the current project.
  # For example, to install project dependencies and perform other setup tasks, run:
  #
  #     $ mix setup
  #
  # See the documentation for `Mix` for more info on aliases.
  defp aliases do
    [
      setup: [
        "deps.get",
        "cmd npm ci",
        "cmd --cd graph_host uv sync --frozen",
        "assets.setup",
        "assets.build"
      ],
      "assets.setup": ["esbuild.install --if-missing"],
      "assets.build": [
        "compile",
        "regent_ui.assets",
        "regent_identity.assets",
        "esbuild keyfleet"
      ],
      "assets.deploy": [
        "regent_ui.assets",
        "regent_identity.assets",
        "esbuild keyfleet --minify",
        "phx.digest"
      ],
      # The database is prepared before the site starts: its job queue starts
      # only on a migrated database.
      test: ["keyfleet.setup_local_auth", "test"],
      "test.external": ["test --only external"],
      precommit: [
        "compile --warnings-as-errors",
        "deps.unlock --check-unused",
        "cmd mix hex.audit",
        "format --check-formatted",
        "credo --strict",
        "cmd env SOBELOW_HOME=_build/sobelow mix sobelow --exit",
        # Ash 3.32.1's retained policy-check compile dependencies (ash #2886) set the
        # floor: each resource adds its domain's edge and one per custom policy check
        # module; Ash's built-in actor checks add none.
        # Agents' check-in records add two: their domain and the OwnProfile check.
        # Wallet steps add three: their domain, the Build action and the LinkedSigner check.
        # The router adds one: its pipelines read the content security policies as they compile.
        # The early-access list adds one: its domain.
        # Shards add two: the ShardEvent and EditsRestriction records, each with its domain.
        # Mutes add two: their domain and the OwnMute check.
        # Notebooks add two: the Hub and Handoff records, each with its domain.
        # Code adds two: the Repository and Push records, each with its domain.
        "xref graph --label compile-connected --fail-above 45",
        "cmd --cd graph_host uv run --frozen --offline pytest -q",
        "test --warnings-as-errors",
        "ash.codegen --check",
        "keyfleet.route_handoff --check"
      ]
    ]
  end
end
