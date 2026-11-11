defmodule Keyfleet.Keys.AgentKey do
  @moduledoc """
  Which of a person's paired agents is on which of their Keys in a fleet, set
  on the Account page's Your Keys or by an agent paired with them
  (`Keyfleet.Keys.Checks.ActsForPerson`). While the person's wallets hold the
  Key and the agent's pairing lasts, the agent writes as that Key there in
  place of its person's Keys (`Keyfleet.Keys.identity/2`,
  `Keyfleet.Keys.held_keys/2`), unless its own wallet holds one of the
  fleet's Keys; an agent on no Key writes as its person's Key
  (`Keyfleet.Keys.PostingKey`).

  A Key has one agent at most, and an agent one Key in a fleet. Putting an
  agent on a Key takes it off the Key it was on in that fleet and takes that
  Key's agent off; naming no agent takes the Key's agent off. All of it is one
  write (`Keyfleet.Keys.Changes.PutAgent`), so a refused one changes nothing.

  The agent is named by its wallet and kept by its pairing's id
  (`RegentAgents.PairedAgent`'s `id`, the `Keyfleet.Actors.Agent`'s
  `pairing_id`), checked against the person's pairings as they stand when it
  is saved: unpairing an agent ends its place on a Key, and pairing it again
  starts with none. Only its own person, or their agent, sets it, and only on
  a Key the person's wallets hold now (`Keyfleet.Keys.Validations.HeldByPerson`).

  It is kept with the Key's ownership record as it stood when it was saved
  (`ownership_epoch`), and counts only while the Key stays in that record and
  one of the person's wallets holds it (`Keyfleet.Keys.placed_on?/3`): a Key
  that changes hands, even between the person's own wallets or back to them,
  has no agent on it. The agent stays paired; it is on no Key in the fleet.

  Only the person takes an agent off a Key or moves one that is on a Key; an
  agent of theirs puts an agent that is on no Key in the fleet, itself
  included, onto a Key with none (`Keyfleet.Keys.Errors.PersonOnlyError`
  otherwise). Two writes at once run one after the other
  (`Keyfleet.Keys.Changes.PutAgent`). Each reads only their own person's;
  which Key any agent is on is read by trusted code alone, through
  `Keyfleet.Keys.assigned_keys/2`.
  """
  use Ash.Resource,
    domain: Keyfleet.Keys,
    data_layer: AshPostgres.DataLayer,
    authorizers: [Ash.Policy.Authorizer]

  @max_bigint 9_223_372_036_854_775_807

  postgres do
    table "agent_keys"
    repo(Keyfleet.Repo)

    check_constraints do
      check_constraint(:token_id, "agent_keys_positive_token", check: "token_id > 0")

      check_constraint(:ownership_epoch, "agent_keys_positive_epoch",
        check: "ownership_epoch >= 1"
      )
    end
  end

  actions do
    create :assign do
      accept [:fleet_id, :token_id]

      argument :agent_wallet, :string,
        allow_nil?: true,
        constraints: [match: ~r/\A0x[0-9a-fA-F]{40}\z/]

      change set_attribute(:human_account_id, actor(:human_account_id))
      upsert? true
      upsert_identity :one_agent_per_key
      upsert_fields [:paired_agent_id, :ownership_epoch, :updated_at]
      validate Keyfleet.Graph.Validations.KnownFleet
      # Checked once the policy has let a person through, in this order.
      validate Keyfleet.Keys.Validations.HeldByPerson, before_action?: true
      change Keyfleet.Keys.Changes.PutAgent
    end

    # The agent the person's other Key in the fleet had, taken off it when
    # the person puts the agent onto another (`Keyfleet.Keys.Changes.PutAgent`),
    # read from the person's own rows. A row whose Key has changed hands puts
    # no agent anywhere, and `PutAgent` clears it for whoever's write needs
    # its place.
    destroy :release do
      require_atomic? false
    end

    read :read do
      primary? true
    end

    # Every Key the person has put one of their agents on, every fleet.
    read :of_person do
      filter expr(human_account_id == ^actor(:human_account_id) and not is_nil(paired_agent_id))
    end

    # The Keys the agents with these wallets are on in a fleet, each by its
    # wallet's current pairing, with that wallet (`:agent_wallet`). Whether
    # the person still holds each Key is `Keyfleet.Keys.assigned_keys/2`'s,
    # the one reader.
    read :of_agents do
      argument :fleet_id, :string, allow_nil?: false
      argument :wallets, {:array, :string}, allow_nil?: false

      filter expr(
               fleet_id == ^arg(:fleet_id) and
                 fragment(
                   "? IN (SELECT pairing.id FROM regent_agents.paired_agents AS pairing WHERE pairing.wallet = ANY(?))",
                   paired_agent_id,
                   ^arg(:wallets)
                 )
             )

      prepare build(load: [:agent_wallet])
    end
  end

  # A person, and an agent paired with a person who has signed in here, carry
  # the person's account (`Keyfleet.Actors.Agent`'s `human_account_id`), as
  # `Keyfleet.Keys.Checks.ActsForPerson` asks; nobody else does.
  policies do
    # Only the person takes a Key's agent off. An agent names an agent to put
    # on, and is refused under lock if that would move one or replace one
    # (`Keyfleet.Keys.Changes.PutAgent`), so it never reaches `:release`.
    policy action(:assign) do
      forbid_unless expr(not is_nil(^actor(:human_account_id)))
      authorize_if actor_attribute_equals(:role, :human)
      authorize_if expr(not is_nil(^arg(:agent_wallet)))
    end

    policy action(:of_person) do
      authorize_if expr(not is_nil(^actor(:human_account_id)))
    end

    policy action(:read) do
      authorize_if expr(human_account_id == ^actor(:human_account_id))
    end

    # Only the person takes an agent off a Key, moving it or not.
    policy action(:release) do
      forbid_unless actor_attribute_equals(:role, :human)
      authorize_if expr(human_account_id == ^actor(:human_account_id))
    end

    # Which Key each agent acts as is public, but pairings are for trusted
    # code only.
    policy action(:of_agents) do
      authorize_if actor_attribute_equals(:role, :system)
    end
  end

  attributes do
    uuid_primary_key :id
    attribute :human_account_id, :integer, allow_nil?: false, public?: true

    attribute :token_id, :integer,
      allow_nil?: false,
      public?: true,
      constraints: [min: 1, max: @max_bigint]

    # The agent's pairing (`RegentAgents.PairedAgent`), nil once its person
    # took it off the Key.
    attribute :paired_agent_id, :uuid, public?: true

    # The Key's ownership record (`Keyfleet.Keys.KeyAttachment`) when the row
    # was saved; the row counts only while the Key is still in it.
    attribute :ownership_epoch, :integer,
      allow_nil?: false,
      public?: true,
      constraints: [min: 1, max: @max_bigint]

    update_timestamp :updated_at, public?: true
  end

  calculations do
    # The wallet of the agent on the Key while its pairing lasts, nil once it
    # is unpaired. Read in SQL, since pairings are for trusted code only.
    calculate :agent_wallet,
              :string,
              expr(
                fragment(
                  "(SELECT pairing.wallet FROM regent_agents.paired_agents AS pairing WHERE pairing.id = ?)",
                  paired_agent_id
                )
              )
  end

  relationships do
    belongs_to :fleet, Keyfleet.Fleets.Fleet do
      attribute_type :string
      allow_nil? false
      public? true
    end
  end

  identities do
    identity :one_agent_per_key, [:human_account_id, :fleet_id, :token_id]
    identity :one_key_per_agent, [:paired_agent_id, :fleet_id]
  end
end
