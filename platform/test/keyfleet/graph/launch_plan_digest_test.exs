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
    "floor_price" => "0.000001",
    "minimum_regent_raised" => "250000.5"
  }

  test "a plan version's digest is the one the API contract documents for agents" do
    assert LaunchPlanDigest.digest("fibonacci_cascade", "launch_card#4", 2, @plan) ==
             "0x71980caf2d08068cc3d699ad06fdb561ecafcbaffa68c31c4c1f05f4f1cc84a3"
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
