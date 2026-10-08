defmodule Keyfleet.Polls.Action do
  @moduledoc """
  One move a round offers: the `id` the outside game or service names it by,
  which is what a vote sends and what wins, and a `label` saying what it does.
  """
  use Ash.Resource, data_layer: :embedded

  attributes do
    attribute :id, :string,
      allow_nil?: false,
      public?: true,
      constraints: [min_length: 1, max_length: 64, trim?: false]

    attribute :label, :string,
      allow_nil?: false,
      public?: true,
      constraints: [min_length: 1, max_length: 200]
  end
end
