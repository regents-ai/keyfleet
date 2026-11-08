defmodule Keyfleet.Repo.Migrations.OAuthClientScopes do
  @moduledoc """
  Connected apps registered before the agent permission (`keyfleet.agent`)
  have only the identity one, and the consent page no longer adds it while a
  person looks at it. This gives every such app both permissions, as an app
  registering now gets them.

  It only inserts (`RegentOAuth.Migration.ClientScopes`): no existing row is
  changed or deleted, and every token still needs the person's consent for each
  permission. Up only: it keeps no record of which links it made.
  """

  use Ecto.Migration

  def up do
    execute("SET LOCAL lock_timeout = '5s'")

    RegentOAuth.Migration.ClientScopes.up(["regent.identity.manage", "keyfleet.agent"])
  end
end
