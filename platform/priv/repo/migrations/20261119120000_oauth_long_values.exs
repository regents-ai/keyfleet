defmodule Keyfleet.Repo.Migrations.OAuthLongValues do
  @moduledoc """
  Connected apps may send values longer than 255 characters: ChatGPT sends a
  `state` that long, which Allow could not store. `RegentOAuth.Migration.V4`
  lifts that limit from a code's `state` and callback (`oauth_tokens.state` and
  `redirect_uri`) and from an app's name, callbacks and keys address
  (`oauth_clients.name`, `redirect_uris` and `jwks_uri`).

  No row changes and no table is rewritten: each column only loses its length
  limit. Each table is locked while its definition changes, waiting at most
  five seconds for the lock. A machine already serving fails each query it
  prepared for the old types once on each database connection, then prepares
  it afresh; a machine started after this migration is unaffected.
  """

  use Ecto.Migration

  def up do
    execute("SET LOCAL lock_timeout = '5s'")

    RegentOAuth.Migration.V4.up()
  end
end
