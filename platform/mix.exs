defmodule Keyfleet.MixProject do
  use Mix.Project

  # Shared Regent libraries, each pinned to one published commit. To move a pin,
  # change its ref and run `mix deps.update <name>`.
  @elixir_utils "https://github.com/regents-ai/elixir-utils.git"
  @elixir_utils_ref "7a876e8673a230e8fb2f7b6f64fe1dec5579fab8"
  @design_system "https://github.com/regents-ai/design-system.git"
  @design_system_ref "4239c53a563461217b25c5c0c1e2228d9e90cf38"
  @regents "https://github.com/regents-ai/regents.git"
  @regents_ref "0d5d18c2f4501a6a5bd00b0bedb005677d8876cc"

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
      {:ash, "~> 3.33.0"},
      {:ash_postgres, "~> 2.13.0"},
      {:igniter, "== 0.8.4", only: [:dev, :test], runtime: false},
      {:mdex, "== 0.13.3"},
      # regent_identity names regent_privy by a sibling path; this pin replaces it.
      {:regent_privy,
       git: @elixir_utils, ref: @elixir_utils_ref, sparse: "privy", override: true},
      {:regent_identity, git: @regents, ref: @regents_ref, sparse: "identity"},
      {:regent_ui, git: @design_system, ref: @design_system_ref, sparse: "regent_ui"},
      {:regent_agent_access, git: @elixir_utils, ref: @elixir_utils_ref, sparse: "agent_access"},
      {:siwa, git: @elixir_utils, ref: @elixir_utils_ref, sparse: "siwa/siwa-elixir/apps/siwa"},
      {:regent_chain, git: @elixir_utils, ref: @elixir_utils_ref, sparse: "chain"},
      {:simple_sat, "~> 0.1"},
      {:sourceror, "~> 1.12", only: [:dev, :test], runtime: false},
      {:lazy_html, ">= 0.1.0", only: :test},
      {:esbuild, "~> 0.10", runtime: Mix.env() == :dev},
      {:telemetry_metrics, "~> 1.0"},
      {:telemetry_metrics_prometheus_core, "~> 1.2"},
      {:telemetry_poller, "~> 1.0"},
      {:sentry, "~> 13.0"},
      {:jason, "~> 1.2"},
      {:yaml_elixir, "~> 2.12"},
      {:ex_secp256k1, "~> 0.8.0"},
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
      "test.external": ["test --only external"],
      precommit: [
        "compile --warnings-as-errors",
        "deps.unlock --check-unused",
        "format --check-formatted",
        "credo --strict",
        "cmd env SOBELOW_HOME=_build/sobelow mix sobelow --exit",
        # Ash 3.32.1's retained policy-check compile dependencies (ash #2886) set the
        # floor: each resource adds its domain's edge and one per policy check module.
        # The keeper's transaction record adds one more: its functions come from Calls.
        # The launch plan revisions table adds two: its domain and the SystemActor check.
        # Agents' check-in records add two: their domain and the OwnProfile check.
        # Wallet steps add three: their domain, the Build action and the LinkedSigner check.
        "xref graph --label compile-connected --fail-above 69",
        "cmd --cd graph_host uv run --frozen --offline pytest -q",
        "test --warnings-as-errors",
        "ash.codegen --check",
        "keyfleet.route_handoff --check",
        "keyfleet.sync_agent_clients --check"
      ]
    ]
  end
end
