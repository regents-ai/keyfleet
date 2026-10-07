# Draws each test key with the site's own trait reader and draw, Keyfleet.Traits, and compares with what the page showed.
# From platform/: MIX_ENV=test mix run --no-start ../docs/still-pictures/parity.exs <trait table file> <keys.json> <report.json>
[table_path, keys_path, report_path] = System.argv()
hash = Keyfleet.Traits.keccak256(File.read!(table_path))
directory = Path.join(System.tmp_dir!(), "keyfleet-parity")
File.mkdir_p!(directory)
File.cp!(table_path, Path.join(directory, hash <> ".json"))
Application.put_env(:keyfleet, Keyfleet.Traits, directory: directory)
table = Keyfleet.Traits.table!(hash)
ids = ~w(exterior metal shell foil emblem rim patina crown)
report = Jason.decode!(File.read!(report_path))["report"]
IO.puts("table #{hash}")
for %{"key" => key, "seed" => seed} <- Jason.decode!(File.read!(keys_path)) do
  drawn = table |> Keyfleet.Traits.draw(seed) |> Enum.map(&elem(&1, 1))
  page = Enum.map(ids, &Enum.find(report, fn r -> r["key"] == key end)["traits"][&1])
  IO.puts("key #{key}: #{if drawn == page, do: "same 8 of 8", else: "DIFFERENT #{inspect(Enum.zip(drawn, page) |> Enum.reject(fn {a, b} -> a == b end))}"}")
end
