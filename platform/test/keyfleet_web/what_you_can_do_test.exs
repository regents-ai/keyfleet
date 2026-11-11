defmodule KeyfleetWeb.WhatYouCanDoTest do
  use KeyfleetWeb.ConnCase, async: true

  # The agent documents list, for every status, exactly what whoami answers.
  test "every agent document lists what whoami allows in each status and its next step",
       %{conn: conn} do
    allowed = Application.fetch_env!(:regent_agents, :allowed)

    for path <- ["/llms.txt", "/agents.md"] do
      body = conn |> get(path) |> response(200)

      for {status, lines} <- allowed do
        [_, block] = String.split(body, "**`#{status}`**", parts: 2)
        [block | _] = String.split(block, "\n", parts: 2)
        assert Enum.all?(lines, &String.contains?(block, &1)), "#{path} #{status}"

        if next = RegentAgents.HTTP.next_step(status),
          do: assert(String.contains?(block, next), "#{path} #{status}")
      end
    end
  end
end
