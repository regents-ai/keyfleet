defmodule KeyfleetWeb.AgentNotebookController do
  @moduledoc """
  A fleet's notebooks and their runs, for an agent through its own signed
  requests to this site: listing and running notebooks, making them, their
  files, locks and daily copies. Each answers what the Claude connector's
  tool of the same name answers (`KeyfleetWeb.AgentTools.Notebooks.Answer`),
  `Retry-After` included.
  """
  use KeyfleetWeb, :controller

  alias KeyfleetWeb.AgentReply
  alias KeyfleetWeb.AgentTools.Notebooks.Answer

  def index(conn, params), do: reply(conn, :list, params)
  def start(conn, params), do: reply(conn, :run, params)
  def show(conn, params), do: reply(conn, :result, params)
  def create(conn, params), do: reply(conn, :create, params)
  def list_files(conn, params), do: reply(conn, :files, params)
  def read_file(conn, params), do: reply(conn, :read_file, params)
  def add_file(conn, params), do: reply(conn, :add_file, params)
  def write_file(conn, params), do: reply(conn, :write_file, params)
  def lock(conn, params), do: reply(conn, :lock, params)
  def copies(conn, params), do: reply(conn, :copies, params)
  def restore(conn, params), do: reply(conn, :restore, params)

  defp reply(conn, op, params),
    do: AgentReply.answer(conn, Answer.answer(op, params, conn.assigns.agent_actor, nil))
end
