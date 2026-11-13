defmodule KeyfleetWeb.LiveCrashes do
  @moduledoc """
  Keeps the browser's session and the page's own state out of the line a live
  page writes when it fails.

  A live page mounts inside the message that joins it to its socket, so a mount
  that raises ends the page's process with that join as the report's last
  message, and Elixir prints it whole: the page's signed tokens, the connect
  parameters with the form token, and the socket the browser connected with,
  which holds the decoded cookie session (the sign-in's lineage and live socket
  id among them). A callback that matches none of its heads also prints its
  arguments on the first line of the stack: a mount's session, or the socket
  with every assign the page holds.

  This `:logger` primary filter rewrites a live page's report before Elixir
  translates it: the join becomes `{Phoenix.Channel, :join}`, and each line of
  the stack keeps its function's arity instead of its arguments, as the saved
  errors do. The line still names the page (its process label), the exception
  and where it was raised.
  """

  @doc "Adds the filter to every log event, once, as the site starts."
  def attach, do: :logger.add_primary_filter(__MODULE__, {&__MODULE__.filter/2, nil})

  # Every field is taken by matching: a filter that raises is removed for good.
  @doc false
  def filter(%{msg: {:report, %{label: {:gen_server, :terminate}} = report}} = event, _extra) do
    case report do
      %{
        process_label: {Phoenix.LiveView, _view, _topic},
        last_message: last_message,
        reason: reason
      } ->
        report = %{report | last_message: without_join(last_message), reason: arities(reason)}
        %{event | msg: {:report, report}}

      _other_process ->
        event
    end
  end

  def filter(event, _extra), do: event

  defp without_join({Phoenix.Channel, _payload, _from, %Phoenix.Socket{}}),
    do: {Phoenix.Channel, :join}

  defp without_join(message), do: message

  defp arities({exception, stack}) when is_list(stack),
    do: {exception, Enum.map(stack, &arity/1)}

  defp arities(reason), do: reason

  defp arity({module, function, arguments, location}) when is_list(arguments),
    do: {module, function, length(arguments), location}

  defp arity(frame), do: frame
end
