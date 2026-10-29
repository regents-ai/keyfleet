defmodule KeyfleetWeb.AgentAvatarController do
  @moduledoc """
  An agent's picture, for an agent through its own requests: `start` and
  `remove` are signed, and `upload` takes the bytes at the address `start`
  answered, whose ticket is its permission. Each answers what the Claude
  connector's tool of the same name answers
  (`KeyfleetWeb.AgentTools.Account.Answer`).
  """
  use KeyfleetWeb, :controller

  alias Keyfleet.Agents.Avatar
  alias KeyfleetWeb.AgentReply
  alias KeyfleetWeb.AgentTools.Account.Answer

  def start(conn, params), do: reply(conn, :avatar_start, params)
  def remove(conn, params), do: reply(conn, :avatar_remove, params)

  # A body longer than a picture may be is refused before it is read in full.
  def upload(conn, %{"ticket" => ticket}) do
    cap = Avatar.max_bytes()

    {bytes, conn} =
      case read_body(conn, length: cap, read_length: cap + 1) do
        {:ok, bytes, conn} -> {bytes, conn}
        {:more, _partial, conn} -> {:too_large, conn}
        # A body that stopped coming is none of the picture's bytes.
        {:error, _reason} -> {"", conn}
      end

    type =
      case get_req_header(conn, "content-type") do
        [type] -> type
        _none_or_more -> nil
      end

    AgentReply.answer(conn, Answer.upload(ticket, type, bytes))
  end

  defp reply(conn, op, params),
    do: AgentReply.answer(conn, Answer.answer(op, params, conn.assigns.agent_actor, nil))
end
