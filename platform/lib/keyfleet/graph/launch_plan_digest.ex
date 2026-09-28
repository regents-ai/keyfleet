defmodule Keyfleet.Graph.LaunchPlanDigest do
  @moduledoc """
  The digest of one version of a fleet's launch plan (a `launch_card` in its
  workspace): the value a launch proposal carries as
  `LaunchEnvelope.narrativeDigest`, which `KeyfleetVotes.proposeAutolaunch`
  records as the proposal's `digest`. A reader finds the plan version a
  proposal points to by that digest.

  The digest is `"0x"` followed by 64 lowercase hex characters, the form of a
  `bytes32` the chain reader records:

      "0x" <> hex(sha256("keyfleet-launch-plan-v1\\n" <> canonical_json(%{
        "fleet" => fleet_id,
        "item" => object_id,
        "version" => version,
        "plan" => plan
      })))

  `fleet` and `item` name the plan, so identical text in two fleets, or in two
  plans of one fleet, gives different digests; `version` is the object's
  version, so each edit gives a new one.

  `plan` is the object's `data` with exactly these fourteen fields of the
  pinned `keyfleet_work@0.2.0` pack's `LaunchCard`, each a string or null:
  `title`, `who_we_serve`, `what_we_sell`, `what_works`, `why_raise`,
  `commitments`, `narrative`, `name`, `symbol`, `description`, `website`,
  `image`, `floor_price` and `minimum_regent_raised` (both decimal strings).
  The graph stores every field of an object, so all fourteen are always
  present: a field never set, or removed, is null, and a field set to blank
  text is stored trimmed, as `""`, not as null. `discussion`, the links to
  room posts, is left out: pointing to where a plan was talked about does not
  change the plan. The server-owned
  `sys` block is left out too, so archiving a plan changes its digest only
  through its version.

  `canonical_json` is RFC 8785 (JSON Canonicalization Scheme) for these
  values: object keys sorted (they are all ASCII), no whitespace, integers in
  decimal, strings as UTF-8 with only `"` and `\\` backslash-escaped, `\\b`,
  `\\f`, `\\n`, `\\r` and `\\t` in their short forms and any other character
  below U+0020 as `\\u00xx` in lowercase hex; every other character is written
  as itself. In Python this is
  `json.dumps(value, sort_keys=True, separators=(",", ":"), ensure_ascii=False).encode()`.
  """

  @domain "keyfleet-launch-plan-v1\n"

  @plan_fields ~w(
    title who_we_serve what_we_sell what_works why_raise commitments narrative
    name symbol description website image floor_price minimum_regent_raised
  )

  @doc "The fields of a launch plan's `data` that its digest covers, as named above."
  @spec plan(map()) :: map()
  def plan(data), do: Map.take(data, @plan_fields)

  @doc "The digest of version `version` of launch plan `object_id` in fleet `fleet_id`."
  @spec digest(String.t(), String.t(), pos_integer(), map()) :: String.t()
  def digest(fleet_id, object_id, version, data) do
    body =
      canonical_json(%{
        "fleet" => fleet_id,
        "item" => object_id,
        "version" => version,
        "plan" => plan(data)
      })

    "0x" <> Base.encode16(:crypto.hash(:sha256, [@domain | body]), case: :lower)
  end

  defp canonical_json(map) when is_map(map) do
    members =
      map
      |> Enum.sort_by(fn {key, _value} -> key end)
      |> Enum.map(fn {key, value} -> [string(key), ?:, canonical_json(value)] end)
      |> Enum.intersperse(?,)

    [?{, members, ?}]
  end

  defp canonical_json(text) when is_binary(text), do: string(text)
  defp canonical_json(number) when is_integer(number), do: Integer.to_string(number)
  defp canonical_json(nil), do: "null"

  defp string(text), do: [?", escape(text, []), ?"]

  defp escape(<<>>, acc), do: Enum.reverse(acc)
  defp escape(<<?", rest::binary>>, acc), do: escape(rest, ["\\\"" | acc])
  defp escape(<<?\\, rest::binary>>, acc), do: escape(rest, ["\\\\" | acc])
  defp escape(<<?\b, rest::binary>>, acc), do: escape(rest, ["\\b" | acc])
  defp escape(<<?\f, rest::binary>>, acc), do: escape(rest, ["\\f" | acc])
  defp escape(<<?\n, rest::binary>>, acc), do: escape(rest, ["\\n" | acc])
  defp escape(<<?\r, rest::binary>>, acc), do: escape(rest, ["\\r" | acc])
  defp escape(<<?\t, rest::binary>>, acc), do: escape(rest, ["\\t" | acc])

  defp escape(<<char, rest::binary>>, acc) when char < 0x20 do
    hex = char |> Integer.to_string(16) |> String.downcase() |> String.pad_leading(4, "0")
    escape(rest, ["\\u" <> hex | acc])
  end

  defp escape(<<char::utf8, rest::binary>>, acc), do: escape(rest, [<<char::utf8>> | acc])
end
