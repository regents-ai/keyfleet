# Draws each test key with the site's own Keyfleet.Traits.draw/2 and compares with what the page showed.
# From platform/: MIX_ENV=test mix run --no-start ../docs/still-pictures/parity.exs <table.json> <keys.json> <report.json>
# Keyfleet.Traits does not read Skin's per-companion list yet, so Skin is drawn here with the drawn companion's list.
[table_path, keys_path, report_path] = System.argv()
traits = Jason.decode!(File.read!(table_path))["traits"]
entry = fn name, vals ->
  values = Enum.map(vals, &{&1["name"], &1["weight"]})
  %{name: name, values: values, total: values |> Enum.map(&elem(&1, 1)) |> Enum.sum()}
end
table_for = fn companion ->
  Enum.map(traits, fn
    %{"per" => _, "values" => by} = t -> entry.(t["name"], by[companion || hd(Map.keys(by))])
    t -> entry.(t["name"], t["values"])
  end)
end
ids = ~w(exterior metal shell foil exit reveal frame form skin mark palette habitat motion)
report = Jason.decode!(File.read!(report_path))["report"]
for %{"key" => key, "seed" => seed} <- Jason.decode!(File.read!(keys_path)) do
  companion = table_for.(nil) |> Keyfleet.Traits.draw(seed) |> List.keyfind("Companion", 0) |> elem(1)
  drawn = table_for.(companion) |> Keyfleet.Traits.draw(seed) |> Enum.map(&elem(&1, 1))
  shown = Enum.find(report, &(&1["key"] == key))["traits"]
  page = Enum.map(ids, &shown[&1])
  IO.puts("key #{key}: #{if drawn == page, do: "same 13 of 13", else: "DIFFERENT #{inspect(Enum.zip(drawn, page) |> Enum.reject(fn {a, b} -> a == b end))}"} (#{companion}, #{Enum.at(drawn, 8)})")
end
