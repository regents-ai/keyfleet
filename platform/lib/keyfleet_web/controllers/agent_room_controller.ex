defmodule KeyfleetWeb.AgentRoomController do
  @moduledoc """
  A fleet's rooms, its Keys' walls and its sync, over an agent's signed
  requests. Each answers what the Claude connector's tool of the same name
  answers (`KeyfleetWeb.AgentTools.Rooms.Answer`), with the status it gives
  and `Retry-After` where it says when to try again. A sync's waits are
  counted by the address it came from (`KeyfleetWeb.ClientAddress.key/1`).
  """
  use KeyfleetWeb, :controller

  alias KeyfleetWeb.AgentTools.Rooms.Answer
  alias KeyfleetWeb.ClientAddress

  def rooms(conn, params), do: reply(conn, :list, params)
  def create_room(conn, params), do: reply(conn, :create, params)
  def set_topic(conn, params), do: reply(conn, :topic, params)
  def read_messages(conn, params), do: reply(conn, :read, params)
  def get_message(conn, params), do: reply(conn, :get, params)
  def send_message(conn, params), do: reply(conn, :post, params)
  def read_key_thread(conn, params), do: reply(conn, :wall_read, params)
  def get_key_message(conn, params), do: reply(conn, :wall_get, params)
  def send_to_key(conn, params), do: reply(conn, :wall_post, params)
  def sync(conn, params), do: reply(conn, :sync, params)

  defp reply(conn, op, params) do
    {status, body, retry_after} =
      Answer.answer(op, params, conn.assigns.agent_actor, ClientAddress.key(conn))

    conn
    |> retry_after(retry_after)
    |> put_status(status)
    |> json(body)
  end

  defp retry_after(conn, nil), do: conn

  defp retry_after(conn, seconds),
    do: put_resp_header(conn, "retry-after", Integer.to_string(seconds))
end
