defmodule Keyfleet.OAuthClientScopesMigrationTest do
  # An app registered before the agent permission existed holds only the
  # identity one. The release's migration gives it both, as an app registering
  # now gets them, and leaves a confidential app and every other row as they are.
  use ExUnit.Case, async: false

  alias Ecto.Adapters.SQL

  @prefix "keyfleet_app"
  @migration Keyfleet.Repo.Migrations.OAuthClientScopes

  # Migrations are not part of the compiled app; the database setup before the
  # suite may already have loaded this one.
  setup_all do
    unless Code.ensure_loaded?(@migration),
      do:
        Code.require_file(
          "../../priv/repo/migrations/20261108120000_oauth_client_scopes.exs",
          __DIR__
        )

    :ok
  end

  setup do
    owner = SQL.Sandbox.start_owner!(Keyfleet.Repo, shared: true)
    on_exit(fn -> SQL.Sandbox.stop_owner(owner) end)
  end

  test "an app with only the identity permission gains the agent one; a confidential app gains nothing" do
    identity = scope!("regent.identity.manage")
    old_app = client!(confidential: false)
    private_app = client!(confidential: true)
    link!(old_app, identity)
    link!(private_app, identity)

    assert scopes(old_app) == ["regent.identity.manage"]

    :ok =
      Ecto.Migrator.up(
        Keyfleet.Repo,
        System.unique_integer([:positive]) + 90_000_000_000_000,
        @migration,
        log: false,
        # The sandbox holds the one connection the lock would need.
        migration_lock: false
      )

    assert scopes(old_app) == ["keyfleet.agent", "regent.identity.manage"]
    assert scopes(private_app) == ["regent.identity.manage"]
  end

  # The scope row, as the provider keeps it; the one the release made, if any.
  defp scope!(name) do
    %{rows: [[id]]} =
      SQL.query!(
        Keyfleet.Repo,
        """
        INSERT INTO #{@prefix}.oauth_scopes (id, name, public, inserted_at, updated_at)
        VALUES (gen_random_uuid(), $1, false, now(), now())
        ON CONFLICT (name) DO UPDATE SET name = EXCLUDED.name
        RETURNING id
        """,
        [name]
      )

    id
  end

  # A public PKCE app, as the consent page serves, or a confidential one.
  defp client!(confidential: confidential) do
    %{rows: [[id]]} =
      SQL.query!(
        Keyfleet.Repo,
        """
        INSERT INTO #{@prefix}.oauth_clients
          (id, secret, confidential, pkce, authorization_code_ttl, access_token_ttl,
           refresh_token_ttl, id_token_ttl, inserted_at, updated_at)
        VALUES (gen_random_uuid(), 'secret', $1, $2, 60, 3600, 86400, 3600, now(), now())
        RETURNING id
        """,
        [confidential, not confidential]
      )

    id
  end

  defp link!(client, scope) do
    SQL.query!(
      Keyfleet.Repo,
      "INSERT INTO #{@prefix}.oauth_clients_scopes (client_id, scope_id) VALUES ($1, $2)",
      [client, scope]
    )
  end

  defp scopes(client) do
    %{rows: rows} =
      SQL.query!(
        Keyfleet.Repo,
        """
        SELECT scope.name FROM #{@prefix}.oauth_clients_scopes AS link
        JOIN #{@prefix}.oauth_scopes AS scope ON scope.id = link.scope_id
        WHERE link.client_id = $1 ORDER BY scope.name
        """,
        [client]
      )

    List.flatten(rows)
  end
end
