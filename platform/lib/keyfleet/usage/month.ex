defmodule Keyfleet.Usage.Month do
  @moduledoc """
  One fleet's usage in one calendar month (UTC), the month that starts on
  `month`, as last counted (`counted_at`):

    * `workspace_bytes` and `workspace_items`: how large its workspace
      record stood at the month's end, or now while the month is under way
      (`Keyfleet.Graph.record_size/2`);
    * `chat_posts` and `chat_bytes`: the posts written in its rooms and on
      its Keys' walls during the month, and their words as stored
      (`Keyfleet.Rooms.posts_written/3`). Direct messages are not counted.

  Every figure is counted from the records that hold it, never written in.
  Each count replaces the month's last one. Anyone reads it: the Treasury
  page shows it to anyone.
  """
  use Ash.Resource,
    domain: Keyfleet.Usage,
    data_layer: AshPostgres.DataLayer,
    authorizers: [Ash.Policy.Authorizer]

  postgres do
    table "fleet_usage"
    repo(Keyfleet.Repo)

    check_constraints do
      check_constraint(:month, "fleet_usage_month_start", check: "extract(day FROM month) = 1")
    end
  end

  actions do
    defaults [:read]

    # Counts the fleet's usage in the month starting on `month` and keeps it
    # in place of the month's last count.
    create :count do
      accept [:fleet_id, :month]
      upsert? true
      upsert_fields [:workspace_bytes, :workspace_items, :chat_posts, :chat_bytes, :counted_at]

      change fn changeset, _context ->
        Ash.Changeset.before_action(changeset, &Keyfleet.Usage.Month.counted/1)
      end
    end
  end

  policies do
    policy action_type(:read) do
      authorize_if always()
    end

    policy action(:count) do
      authorize_if actor_attribute_equals(:role, :system)
    end
  end

  attributes do
    attribute :fleet_id, :string, primary_key?: true, allow_nil?: false, public?: true

    # The month's first day.
    attribute :month, :date, primary_key?: true, allow_nil?: false, public?: true

    attribute :workspace_bytes, :integer, allow_nil?: false, public?: true, constraints: [min: 0]
    attribute :workspace_items, :integer, allow_nil?: false, public?: true, constraints: [min: 0]
    attribute :chat_posts, :integer, allow_nil?: false, public?: true, constraints: [min: 0]
    attribute :chat_bytes, :integer, allow_nil?: false, public?: true, constraints: [min: 0]
    attribute :counted_at, :utc_datetime_usec, allow_nil?: false, public?: true
  end

  @doc false
  def counted(changeset) do
    fleet_id = Ash.Changeset.get_attribute(changeset, :fleet_id)
    month = Ash.Changeset.get_attribute(changeset, :month)
    from = DateTime.new!(month, ~T[00:00:00])
    to = DateTime.new!(Date.shift(month, month: 1), ~T[00:00:00])
    workspace = Keyfleet.Graph.record_size(fleet_id, to)
    chat = Keyfleet.Rooms.posts_written(fleet_id, from, to)

    Ash.Changeset.force_change_attributes(changeset, %{
      workspace_bytes: workspace.bytes,
      workspace_items: workspace.items,
      chat_posts: chat.posts,
      chat_bytes: chat.bytes,
      counted_at: DateTime.utc_now()
    })
  end
end
