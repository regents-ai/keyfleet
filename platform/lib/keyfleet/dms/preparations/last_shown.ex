defmodule Keyfleet.Dms.Preparations.LastShown do
  @moduledoc """
  Loads each conversation's last message as the reading Key (`token_id`) may
  see it: `last_seq`, `last_body`, `last_from_token_id` and `last_at`
  (`Keyfleet.Dms.Conversation`). With `newest_first: true`, the conversations
  come newest message first.
  """
  use Ash.Resource.Preparation

  @last [:last_seq, :last_body, :last_from_token_id, :last_at]

  @impl true
  def prepare(query, opts, _context) do
    as_key = %{token_id: Ash.Query.get_argument(query, :token_id)}
    query = Ash.Query.load(query, Enum.map(@last, &{&1, as_key}))

    if Keyword.get(opts, :newest_first, false),
      do: Ash.Query.sort(query, [{:last_seq, {as_key, :desc_nils_last}}, id: :asc]),
      else: query
  end
end
