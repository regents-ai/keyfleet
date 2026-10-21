defmodule KeyfleetWeb.LaunchSteps do
  @moduledoc """
  How many visits take each step into Keyfleet, counted on this site with
  nothing saved: the homepage opened (`home`), "Watch a live fleet" pressed
  (`watch`), "Connect my agent" pressed (`connect`), and a setup line copied,
  by the agent it is for (`copy`). Browsers report each step as it happens
  (`assets/js/launch_steps.ts`, taken in by `KeyfleetWeb.LaunchStepsController`)
  and each report adds one to a Prometheus counter `KeyfleetWeb.Telemetry`
  exports. A report names only the step and, for a copy, the agent: never a
  person, an address, a wallet or a Key. Pairing an agent and buying a Key are
  already in the database, so they are not counted here.

  ## Reading the steps

  Fly scrapes the private metrics listener (`fly.toml`, `[metrics]`) and adds
  the `app` label. Each step over the last day:

      sum by (step) (increase(keyfleet_launch_steps_total{app="keyfleet"}[1d]))

  Setup lines copied over the last day, by agent (`any` is the homepage's
  line for every agent):

      sum by (agent) (increase(keyfleet_launch_setup_copied_total{app="keyfleet"}[1d]))

  `keyfleet_launch_refused_total` counts the reports refused, by reason.
  """

  @steps ~w(home watch connect)

  @doc """
  Counts one decoded report, or refuses it with `:error`: anything but a step
  above, or a copy of an agent the guides don't have, or any other field.
  """
  def record(%{"step" => step} = report) when map_size(report) == 1 and step in @steps do
    :telemetry.execute([:keyfleet, :launch, :step], %{count: 1}, %{step: step})
  end

  def record(%{"step" => "copy", "agent" => agent} = report) when map_size(report) == 2 do
    if agent?(agent),
      do: :telemetry.execute([:keyfleet, :launch, :setup_copied], %{count: 1}, %{agent: agent}),
      else: :error
  end

  def record(_report), do: :error

  # The homepage's line is for any agent; /connect's is the chosen agent's.
  defp agent?("any"), do: true
  defp agent?(agent), do: List.keymember?(KeyfleetWeb.AgentGuides.runtimes(), agent, 0)
end
