defmodule Mix.Tasks.Keyfleet.CheckMembership do
  @shortdoc "Checks that a moved Key, an ended pairing and another fleet's Key reach every place"

  @moduledoc """
  Checks that membership moves through a fleet's rooms, workspace, notebooks
  and code when a Key changes hands, when a person ends their agent's
  pairing, and for an agent whose person holds a Key of another fleet, as
  `Keyfleet.MembershipCheck` describes. It is a test-support task, so it runs
  under the test configuration, on a database of its own:

      MIX_ENV=test MIX_TEST_PARTITION=_membership mix keyfleet.check_membership

  It empties `keyfleet_membership_test` first, then serves the site at
  https://localhost:4502 (or the port `PORT` names) with the browser test
  server's certificate, making it with `openssl` when there is none. It
  needs Postgres as the tests do, and reaches nothing beyond localhost.

  It prints `pass` or `fail` and what it checked for each check, with the
  reason when one failed, then a count, and stops with an error when any
  failed.
  """

  use Mix.Task

  @impl Mix.Task
  def run([]), do: Keyfleet.MembershipCheck.run!()

  def run(_args), do: Mix.raise("Usage: mix keyfleet.check_membership")
end
