defmodule Keyfleet.SharedReadingPropertyTest do
  @moduledoc """
  What keeps the shared readings small whatever a producer hands them: a
  reading is held exactly as given when it is plain data within its kind's
  size, and refused otherwise, leaving the reading held before it in place.
  The table's memory is bounded by its kinds' keys times their sizes only if
  this holds for every reading.
  """
  use ExUnit.Case, async: false
  use ExUnitProperties

  alias Keyfleet.SharedReading

  # Kinds with room for a key no producer writes; the size check is the same
  # function for every kind.
  @kinds [:key_agents, :proposal]
  @id "property-probe"
  @held %{"held" => 1}

  setup do
    on_exit(fn -> Enum.each(@kinds, &SharedReading.delete({&1, @id})) end)
  end

  property "SR-BYTES: only a plain reading within its kind's size replaces the held one" do
    check all {kind, size} <- kind_and_size(),
              extra <- plain(),
              struct? <- boolean(),
              max_runs: 200 do
      key = {kind, @id}
      assert SharedReading.put(key, @held) == :ok

      reading = %{"blob" => :binary.copy("x", size), "extra" => extra}

      reading =
        if struct?,
          do: Map.put(reading, "struct", URI.parse("https://keyfleet.ai")),
          else: reading

      expected =
        cond do
          :erlang.external_size(reading) > SharedReading.bytes(kind) -> {:error, :too_large}
          struct? -> {:error, :not_plain}
          true -> :ok
        end

      assert SharedReading.put(key, reading) == expected
      assert {:ok, %{reading: held, degraded?: false}} = SharedReading.fetch(key)
      assert held == if(expected == :ok, do: reading, else: @held)
      assert :erlang.external_size(held) <= SharedReading.bytes(kind)
    end
  end

  # Half the sizes anywhere up to twice the kind's limit, half within a few
  # hundred bytes of it, where an off-by-one would show.
  defp kind_and_size do
    bind(member_of(@kinds), fn kind ->
      limit = SharedReading.bytes(kind)
      size = one_of([integer(0..(2 * limit)), integer((limit - 300)..(limit + 300))])
      tuple({constant(kind), size})
    end)
  end

  defp plain do
    leaf =
      one_of([
        integer(),
        string(:printable, max_length: 20),
        boolean(),
        constant(nil),
        map(integer(), &Decimal.new/1),
        constant(~D[2026-10-18])
      ])

    tree(leaf, fn child ->
      one_of([
        list_of(child, max_length: 3),
        map_of(string(:alphanumeric, max_length: 5), child, max_length: 3),
        map(list_of(child, max_length: 3), &List.to_tuple/1)
      ])
    end)
  end
end
