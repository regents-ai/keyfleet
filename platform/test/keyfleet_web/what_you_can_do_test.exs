defmodule KeyfleetWeb.WhatYouCanDoTest do
  use KeyfleetWeb.ConnCase, async: true

  # The agent access page lists, for every status, exactly what whoami answers.
  test "the agent access page lists what whoami allows in each status and its next step",
       %{conn: conn} do
    allowed = Application.fetch_env!(:regent_agents, :allowed)
    body = conn |> get("/agents.md") |> response(200)

    for {status, lines} <- allowed do
      [_, block] = String.split(body, "**`#{status}`**", parts: 2)
      [block | _] = String.split(block, "\n", parts: 2)
      assert Enum.all?(lines, &String.contains?(block, &1)), status

      if next = RegentAgents.HTTP.next_step(status),
        do: assert(String.contains?(block, next), status)
    end
  end
end
