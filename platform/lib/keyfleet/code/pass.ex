defmodule Keyfleet.Code.Pass do
  @moduledoc """
  The pass every request to the code store carries, as `Authorization:
  Bearer`: an ES256 JWT signed with the notebook hubs' keys
  (`Keyfleet.Notebooks.Pass.sign/2`), for the audience `keyfleet-code`.

  `fleet` names the one repository it opens and `scope` what it allows:
  `push` (copy and send changes, for the key holder whose wallet is `sub`, as
  `did:pkh:eip155:1:<wallet>`), `read` (copy) or `create` (make the
  repository), the last two with `sub` `keyfleet`. It lasts
  `pass_ttl_seconds`.
  """

  alias Keyfleet.Code
  alias Keyfleet.Notebooks.Pass

  @audience "keyfleet-code"

  @doc "A pass to send changes to the fleet's code as the holder of `wallet`."
  def push(fleet_id, wallet), do: mint(fleet_id, "push", "did:pkh:eip155:1:" <> wallet)

  @doc "A pass to copy the fleet's code, for a key whose edits are restricted."
  def read(fleet_id), do: mint(fleet_id, "read", "keyfleet")

  @doc "A pass to make the fleet's repository."
  def create(fleet_id), do: mint(fleet_id, "create", "keyfleet")

  defp mint(fleet_id, scope, subject) do
    Pass.sign(
      %{"aud" => @audience, "fleet" => fleet_id, "scope" => scope, "sub" => subject},
      Code.config()[:pass_ttl_seconds]
    )
  end
end
