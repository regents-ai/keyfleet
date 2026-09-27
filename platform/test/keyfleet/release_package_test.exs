defmodule Keyfleet.ReleasePackageTest do
  use ExUnit.Case, async: true

  @package_root Path.expand("../..", __DIR__)
  @dockerfile Path.join(@package_root, "Dockerfile")
  @dockerignore Path.join(@package_root, "Dockerfile.dockerignore")
  @fly_template Path.join(@package_root, "fly.toml")
  @fly_staging_template Path.join(@package_root, "fly.staging.toml")
  @context_script Path.join(@package_root, "scripts/build-release-context.sh")
  @release_commands ~w(migrate bootstrap-staging pending-migrations seed-deployment)

  test "PKG-IMAGE and PKG-TEMPLATE ship the release package files" do
    assert File.regular?(@dockerfile)
    assert File.regular?(@dockerignore)
    assert File.regular?(@fly_template)
    assert File.regular?(@fly_staging_template)
    assert File.regular?(@context_script)
    assert File.stat!(@context_script).mode |> Bitwise.band(0o100) != 0
  end

  test "PKG-IMAGE ships every release command as an executable overlay" do
    for command <- @release_commands do
      path = Path.join(@package_root, "rel/overlays/bin/#{command}")

      assert File.regular?(path), "#{command} is missing from the release overlay"

      assert File.stat!(path).mode |> Bitwise.band(0o100) != 0,
             "#{command} would not ship executable"
    end
  end

  # Reading the ignore rules cannot tell you what they admit: a bare directory
  # re-include silently readmits everything beneath it. Only a real build knows,
  # so this asks one. It is tagged :external because it needs a Docker daemon.
  @tag :external
  test "PKG-CONTEXT the ignore rules admit exactly the declared package inputs" do
    context = temporary_directory("release-context")
    output = temporary_directory("release-context-out")

    # A miniature stand-in for the real parent context, holding one file for
    # every rule: package sources, the sealed Python supply, and the things that
    # must never enter -- tests, environment files, host build output, and
    # everything outside the declared allowlist.
    write_files(context, [
      {"platform/lib/app.ex", "defmodule App do\nend\n"},
      {"platform/config/config.exs", "import Config\n"},
      {"platform/assets/js/app.ts", "export const app = 1\n"},
      {"platform/contracts/base-mainnet.json", "{}\n"},
      {"platform/rel/overlays/bin/migrate", "#!/bin/sh\n"},
      {"platform/priv/static/app.css", "body{}\n"},
      {"platform/mix.exs", "defmodule App.MixProject do\nend\n"},
      {"platform/mix.lock", "%{}\n"},
      {"platform/package.json", "{}\n"},
      {"platform/package-lock.json", "{}\n"},
      {"platform/graph_host/pyproject.toml", "[project]\n"},
      {"platform/graph_host/uv.lock", "version = 1\n"},
      {"platform/graph_host/.python-version", "3.12\n"},
      {"platform/graph_host/src/keyfleet_graph/host.py", "HOST = 1\n"},
      {"platform/graph_host/src/keyfleet_graph/__pycache__/host.pyc", "bytecode\n"},
      {"platform/graph_host/third_party/activegraph/LICENSE", "Apache License\n"},
      {"platform/graph_host/tests/test_host.py", "def test(): pass\n"},
      {"platform/graph_host/.venv/bin/python", "local interpreter\n"},
      {"platform/deps/dependency/lib/dependency.ex", "defmodule Dependency do\nend\n"},
      {"platform/_build/prod/lib/app.beam", "host build output\n"},
      {"platform/test/app_test.exs", "defmodule AppTest do\nend\n"},
      {"platform/docs/guide.md", "# guide\n"},
      {"platform/README.md", "# readme\n"},
      {"platform/.env", "SECRET=nope\n"},
      {"platform/.env.example", "SECRET=\n"},
      {"platform/.env.production", "SECRET=nope\n"},
      {"platform/.envrc", "export SECRET=nope\n"},
      {"platform/config/.env", "SECRET=nope\n"},
      {"uv-cache/archive-v0/pydantic", "cache payload\n"},
      {"python-cache/cpython.tar.gz", "interpreter archive\n"},
      {"BUILD-INPUTS.txt", "arch=arm64\n"},
      {"stray.txt", "outside the allowlist\n"}
    ])

    dockerfile = Path.join(context, "context.Dockerfile")
    File.write!(dockerfile, "FROM scratch\nCOPY . /\n")
    File.cp!(@dockerignore, Path.join(context, "context.Dockerfile.dockerignore"))

    {out, status} =
      System.cmd(
        "docker",
        [
          "build",
          "--network=none",
          "--pull=false",
          "--quiet",
          "--file",
          dockerfile,
          "--output",
          "type=local,dest=#{output}",
          context
        ],
        stderr_to_stdout: true
      )

    assert status == 0, out

    assert admitted_files(output) == [
             "platform/assets/js/app.ts",
             "platform/config/config.exs",
             "platform/contracts/base-mainnet.json",
             "platform/graph_host/.python-version",
             "platform/graph_host/pyproject.toml",
             "platform/graph_host/src/keyfleet_graph/host.py",
             "platform/graph_host/third_party/activegraph/LICENSE",
             "platform/graph_host/uv.lock",
             "platform/lib/app.ex",
             "platform/mix.exs",
             "platform/mix.lock",
             "platform/package-lock.json",
             "platform/package.json",
             "platform/priv/static/app.css",
             "platform/rel/overlays/bin/migrate",
             "python-cache/cpython.tar.gz",
             "uv-cache/archive-v0/pydantic"
           ]
  end

  # The script exports every source tree from a commit and leaves env-shaped
  # names out of the export; the guard below is the last look before a context
  # is published, and the only one that sees the sealed Python supply. It is
  # lifted from the script's own source rather than transcribed.

  test "CTX-ENV the script's guard refuses a staging tree carrying an env-shaped file" do
    {scan, refusal} = context_guard()

    dirty = temporary_directory("context-guard-dirty")

    write_files(dirty, [
      {"platform/lib/app.ex", "defmodule App do\nend\n"},
      {"uv-cache/x/.envrc.local", "export SECRET=nope\n"}
    ])

    {out, status} = run_guard(scan, refusal, dirty)

    assert status == 1
    assert out =~ "uv-cache/x/.envrc.local"

    # An oddly cased name is refused too.
    odd_case = temporary_directory("context-guard-odd-case")

    write_files(odd_case, [
      {"platform/lib/app.ex", "defmodule App do\nend\n"},
      {"platform/.ENV", "SECRET=nope\n"}
    ])

    {out, status} = run_guard(scan, refusal, odd_case)

    assert status == 1
    assert out =~ ".ENV"

    clean = temporary_directory("context-guard-clean")

    write_files(clean, [
      {"platform/lib/app.ex", "defmodule App do\nend\n"},
      {"platform/environment.md", "# not a secrets file\n"},
      {"uv-cache/archive-v0/pydantic", "cache payload\n"}
    ])

    assert run_guard(scan, refusal, clean) == {"", 0}
  end

  defp script_lines do
    @context_script
    |> File.read!()
    |> String.split("\n")
  end

  # The guard is the `offender=` scan and the refusal on the line right after it.
  # Where it sits is half of what makes it a guard: it has to run after the
  # sealed archives are unpacked, so it sees their files, and before the previous
  # destination is removed, so a refusal leaves that context in place.
  defp context_guard do
    lines = script_lines()

    [index] = script_line_indexes(lines, &String.starts_with?(&1, "offender="))
    unpacks = script_line_indexes(lines, &String.starts_with?(&1, "tar -xf "))
    [delete] = script_line_indexes(lines, &String.contains?(&1, ~s(rm -rf -- "$destination")))

    assert unpacks != []

    assert Enum.all?(unpacks, &(index > &1)),
           "the scan must run after every sealed archive is unpacked"

    assert index < delete, "the scan must run before the previous destination is removed"

    refusal = Enum.at(lines, index + 1)

    assert String.starts_with?(refusal, ~s([ -z "$offender" ] ||)),
           "the refusal must follow the scan immediately"

    {Enum.at(lines, index), refusal}
  end

  defp script_line_indexes(lines, matches?) do
    for {line, index} <- Enum.with_index(lines), matches?.(String.trim(line)), do: index
  end

  defp run_guard(scan, refusal, staging) do
    preamble = """
    set -euo pipefail
    die() { printf '%s\\n' "$*"; exit 1; }
    staging='#{staging}'
    """

    System.cmd("bash", ["-c", preamble <> scan <> "\n" <> refusal <> "\n"],
      stderr_to_stdout: true
    )
  end

  defp temporary_directory(prefix) do
    path =
      Path.join(
        System.tmp_dir!(),
        "platform-#{prefix}-#{System.unique_integer([:positive])}"
      )

    on_exit(fn -> File.rm_rf!(path) end)
    path
  end

  defp write_files(root, entries) do
    Enum.each(entries, fn {relative, contents} ->
      path = Path.join(root, relative)
      File.mkdir_p!(Path.dirname(path))
      File.write!(path, contents)
    end)
  end

  defp admitted_files(root) do
    root
    |> Path.join("**")
    |> Path.wildcard(match_dot: true)
    |> Enum.reject(&File.dir?/1)
    |> Enum.map(&Path.relative_to(&1, root))
    |> Enum.sort()
  end
end
