defmodule KeyfleetWeb.PublicGuideCliReleaseTest do
  @moduledoc """
  Every public guide that tells an agent to install regents-cli, with both its
  browser and MCP parts, names the same release, the source commit the Makefile pins (`REGENTS_CLI_REV`, which
  `make check-cli` checks the commands against), and one wheel digest. On
  9 November 2026 `/llms.txt` named another commit and a digest PyPI never
  published, while `/agents.md` named the right ones.
  """
  use ExUnit.Case, async: true

  test "every guide naming a regents-cli release names the pinned commit and one digest" do
    [pin] =
      Regex.run(~r/^REGENTS_CLI_REV := ([0-9a-f]{40})$/m, File.read!("../Makefile"),
        capture: :all_but_first
      )

    guides =
      for path <- Path.wildcard("priv/public/**/*.md"),
          text = File.read!(path),
          text =~ "regents-cli[browser,mcp]==",
          do: {path, text}

    assert guides != []

    releases =
      for {_path, text} <- guides,
          [release] <-
            Regex.scan(~r/regents-cli\[browser,mcp\]==(\d+(?:\.\d+)*)/, text,
              capture: :all_but_first
            ),
          uniq: true,
          do: release

    assert [_one] = releases

    commits =
      for {path, text} <- guides,
          [commit] <-
            Regex.scan(~r/source commit `([0-9a-f]{40})`/, text, capture: :all_but_first),
          do: {path, commit}

    assert commits != []
    for {path, commit} <- commits, do: assert({path, commit} == {path, pin})

    digests =
      for {_path, text} <- guides,
          [digest] <-
            Regex.scan(~r/SHA256(?: is)? `([0-9a-f]{64})`/, text, capture: :all_but_first),
          uniq: true,
          do: digest

    assert [_one] = digests
  end
end
