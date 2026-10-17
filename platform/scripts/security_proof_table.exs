# Renders and validates the security red-team proof table from the check
# catalog. Run with: mix run scripts/security_proof_table.exs
#
# It reads priv/security/redteam_checks.yml, checks that every referenced probe
# test file exists (so the catalog can't drift from the suite), and prints the
# proof table as Markdown. Exits non-zero if a referenced probe file is missing.

catalog = YamlElixir.read_from_file!("priv/security/redteam_checks.yml")
meta = catalog["meta"]
checks = catalog["checks"]

verdict_label = %{
  "safe_by_code" => "SAFE (code)",
  "safe_by_design" => "SAFE (design)",
  "needs_dynamic" => "NEEDS LIVE RUN",
  "na" => "N/A"
}

# Validate: every `test/...exs` path a probe names must exist on disk.
missing =
  checks
  |> Enum.flat_map(fn check ->
    Regex.scan(~r{test/\S+\.exs}, check["probe"] || "")
    |> List.flatten()
    |> Enum.reject(&File.exists?/1)
    |> Enum.map(&{check["id"], &1})
  end)
  |> Enum.uniq()

IO.puts("# Red-team proof table — #{meta["date"]} (base #{meta["base_commit"]})\n")
IO.puts("Scope: #{meta["scope"]}\n")
IO.puts("Run the suite: `#{meta["run_suite"]}` (add `--include dynamic` for the tagged live probes)\n")

IO.puts("| Check | Category | Verdict | Attack | Control | Probe | Disable toggle | Live run |")
IO.puts("|---|---|---|---|---|---|---|---|")

for check <- checks do
  cell = fn value -> value |> to_string() |> String.replace("|", "\\|") |> String.replace("\n", " ") end

  IO.puts(
    "| #{check["id"]} | #{check["category"]} | #{verdict_label[check["verdict"]]} | " <>
      "#{cell.(check["attack"])} | #{cell.(check["control"])} | #{cell.(check["probe"])} | " <>
      "#{cell.(check["disable_toggle"])} | #{if check["needs_dynamic"], do: cell.(check["dynamic_note"] || "yes"), else: "—"} |"
  )
end

counts = Enum.frequencies_by(checks, & &1["verdict"])
IO.puts("\n## Totals\n")
for {verdict, label} <- verdict_label, n = counts[verdict], n && n > 0 do
  IO.puts("- #{label}: #{n}")
end

dynamic = Enum.filter(checks, & &1["needs_dynamic"])
IO.puts("\n## Items still needing the live/fork run (#{length(dynamic)})\n")
for check <- dynamic, do: IO.puts("- **#{check["id"]}** — #{check["dynamic_note"] || check["attack"]}")

if missing == [] do
  IO.puts("\nAll referenced probe files exist.")
else
  IO.puts("\nMISSING probe files:")
  for {id, path} <- missing, do: IO.puts("- #{id}: #{path}")
  System.halt(1)
end
