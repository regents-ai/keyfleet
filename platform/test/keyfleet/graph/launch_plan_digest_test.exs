defmodule Keyfleet.Graph.LaunchPlanDigestTest do
  use ExUnit.Case, async: true

  alias Keyfleet.Graph.LaunchPlanDigest

  # The example the API contract gives agents, computed apart from this code
  # with Python's json.dumps(sort_keys=True, separators=(",", ":"),
  # ensure_ascii=False) and hashlib.sha256.
  @plan %{
    "title" => "Cascade Research \"v1\"",
    "who_we_serve" => "Funds that read filings",
    "what_we_sell" => "A weekly brief\n\tin plain words",
    "what_works" => nil,
    "why_raise" => nil,
    "commitments" => nil,
    "narrative" => "Café ☕ — naïve 🚀 back\\slash",
    "name" => "Cascade Research",
    "symbol" => "CSR",
    "description" => nil,
    "website" => "https://example.test/a/b",
    "image" => nil,
    "required_regent_raised" => "250000.5"
  }

  test "a plan version's digest is the one the API contract documents for agents" do
    assert LaunchPlanDigest.digest("fibonacci_cascade", "launch_card#4", 2, @plan) ==
             "0xb03009c6a6684970069520afd2e49bc7004e23ed5c6a73b4f0b9d26872985738"
  end

  test "where a plan was discussed does not change its digest" do
    discussed = Map.put(@plan, "discussion", [%{"room" => "voting", "seq" => 3}])

    assert LaunchPlanDigest.digest("fibonacci_cascade", "launch_card#4", 2, discussed) ==
             LaunchPlanDigest.digest("fibonacci_cascade", "launch_card#4", 2, @plan)
  end

  test "the same plan text in two fleets has two digests" do
    refute LaunchPlanDigest.digest("fibonacci_cascade", "launch_card#4", 2, @plan) ==
             LaunchPlanDigest.digest("fibonacci_syndicate", "launch_card#4", 2, @plan)
  end
end
