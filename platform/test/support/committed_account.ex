defmodule Keyfleet.CommittedAccount do
  @moduledoc """
  Removes a test account that was committed outside the sandbox, with every
  sign-in record bound to it, so a test run leaves its database as it found it.
  Callers inside ExUnit run it through `unboxed_run`.
  """

  import Ecto.Query

  alias Keyfleet.Repo

  # Ash is bypassed on purpose: neither resource has a destroy action, because the
  # site never removes an account; this teardown deletes only the test's rows.
  def remove!(privy_did) do
    account_ids =
      from(account in "platform_human_users",
        prefix: "regent_names",
        where: account.privy_user_id == ^privy_did,
        select: account.id
      )

    Repo.delete_all(
      from(row in "session_authorities", where: row.human_account_id in subquery(account_ids))
    )

    Repo.delete_all(
      from(account in "platform_human_users",
        prefix: "regent_names",
        where: account.privy_user_id == ^privy_did
      )
    )
  end
end
