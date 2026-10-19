defmodule Keyfleet.Repo.Migrations.AddTreasuryUpkeep do
  @moduledoc """
  The upkeep's lines and its switch (`Keyfleet.Treasury.UpkeepLine`,
  `Keyfleet.Treasury.UpkeepSwitch`). The switch's one row is created paused,
  so after the release nothing is pressed until an admin resumes it.

  Written by hand in the shape `mix ash_postgres.generate_migrations` gives;
  the row is the switch's own statement.
  """

  use Ecto.Migration

  def up do
    create table(:treasury_upkeep_lines, primary_key: false) do
      add(:id, :uuid, null: false, default: fragment("gen_random_uuid()"), primary_key: true)
      add(:run_id, :uuid, null: false)
      add(:fleet_id, :text)
      add(:step, :text)
      add(:proposal, :bigint)
      add(:outcome, :text, null: false)
      add(:reason, :text)
      add(:opens_at, :utc_datetime)
      add(:amount, :bigint)
      add(:transaction_hash, :text)
      add(:raw_transaction, :text)

      add(:inserted_at, :utc_datetime_usec,
        null: false,
        default: fragment("(now() AT TIME ZONE 'utc')")
      )

      add(:updated_at, :utc_datetime_usec,
        null: false,
        default: fragment("(now() AT TIME ZONE 'utc')")
      )
    end

    create constraint(:treasury_upkeep_lines, :treasury_upkeep_lines_transaction_hash_shape,
             check: """
               transaction_hash ~ '^0x[0-9a-f]{64}$'
             """
           )

    create constraint(:treasury_upkeep_lines, :treasury_upkeep_lines_raw_transaction_shape,
             check: """
               raw_transaction ~ '^0x02[0-9a-f]+$'
             """
           )

    create constraint(:treasury_upkeep_lines, :treasury_upkeep_lines_signed,
             check: """
               num_nonnulls(transaction_hash, raw_transaction) = CASE outcome WHEN 'skipped' THEN 0 ELSE 2 END
             """
           )

    create constraint(:treasury_upkeep_lines, :treasury_upkeep_lines_reason,
             check: """
               (reason IS NULL) = (outcome IN ('sent', 'done'))
             """
           )

    create constraint(:treasury_upkeep_lines, :treasury_upkeep_lines_opens_at,
             check: """
               num_nonnulls(opens_at) = CASE reason WHEN 'not_due' THEN 1 ELSE 0 END
             """
           )

    create constraint(:treasury_upkeep_lines, :treasury_upkeep_lines_proposal,
             check: """
               num_nonnulls(proposal) = CASE step WHEN 'carry_out' THEN 1 ELSE 0 END
             """
           )

    create constraint(:treasury_upkeep_lines, :treasury_upkeep_lines_amount,
             check: """
               amount IS NULL OR (step = 'convert' AND amount > 0)
             """
           )

    create table(:treasury_upkeep_switch, primary_key: false) do
      add(:id, :bigint, null: false, primary_key: true)
      add(:paused, :boolean, null: false)
      add(:changed_by, :bigint)

      add(:updated_at, :utc_datetime_usec,
        null: false,
        default: fragment("(now() AT TIME ZONE 'utc')")
      )
    end

    create constraint(:treasury_upkeep_switch, :treasury_upkeep_switch_one_row,
             check: """
               id = 1
             """
           )

    execute("INSERT INTO keyfleet_app.treasury_upkeep_switch (id, paused) VALUES (1, true);")
  end

  def down do
    execute("DELETE FROM keyfleet_app.treasury_upkeep_switch WHERE id = 1;")

    drop_if_exists(constraint(:treasury_upkeep_switch, :treasury_upkeep_switch_one_row))

    drop(table(:treasury_upkeep_switch))

    drop_if_exists(constraint(:treasury_upkeep_lines, :treasury_upkeep_lines_amount))

    drop_if_exists(constraint(:treasury_upkeep_lines, :treasury_upkeep_lines_proposal))

    drop_if_exists(constraint(:treasury_upkeep_lines, :treasury_upkeep_lines_opens_at))

    drop_if_exists(constraint(:treasury_upkeep_lines, :treasury_upkeep_lines_reason))

    drop_if_exists(constraint(:treasury_upkeep_lines, :treasury_upkeep_lines_signed))

    drop_if_exists(
      constraint(:treasury_upkeep_lines, :treasury_upkeep_lines_raw_transaction_shape)
    )

    drop_if_exists(
      constraint(:treasury_upkeep_lines, :treasury_upkeep_lines_transaction_hash_shape)
    )

    drop(table(:treasury_upkeep_lines))
  end
end
