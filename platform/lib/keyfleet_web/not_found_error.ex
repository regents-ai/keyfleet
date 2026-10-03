defmodule KeyfleetWeb.NotFoundError do
  @moduledoc false
  defexception message: "Not found", plug_status: 404
end
