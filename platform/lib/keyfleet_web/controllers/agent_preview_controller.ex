defmodule KeyfleetWeb.AgentPreviewController do
  @moduledoc """
  What a write would do, before it is sent (`KeyfleetWeb.Preview`). Nothing
  is written.
  """
  use KeyfleetWeb, :controller

  alias KeyfleetWeb.{Preview, Refusal}

  def preview(conn, %{"tool" => tool, "input" => input}) do
    case Preview.preview(tool, input, conn.assigns.agent_actor) do
      {:ok, preview} ->
        json(conn, preview)

      :tool_unknown ->
        Refusal.json(conn, 422, "preview_tool_unknown")

      {:missing, names} ->
        hint =
          "This tool's input names #{Enum.join(names, ", ")}. Add them, then preview it again."

        conn |> put_status(422) |> json(Refusal.body("invalid_request", hint))
    end
  end
end
