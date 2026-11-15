defmodule KeyfleetWeb.Preview do
  @moduledoc """
  What one write would do, told before it is sent and without sending it:
  the request its browser tool makes from the input, the Key it would be
  written as, who would see it (`audience`), its size against the
  operation's limit, and each refusal already certain from the request and
  the agent's standing.

  A workspace write whose request is taken is also checked whole, as it
  would be if it were sent now: its action runs with `input_check` in its
  context, so its validations spend no write allowance, its policy reads the
  agent's standing, and the fleet's writer stamps its command at its turn
  and has the graph decide it without writing it
  (`Keyfleet.Graph.Workspace.Relay`). Its refusal is the one the write's
  signed request would answer (`KeyfleetWeb.WorkspaceRefusal`), in place of
  the preview's own word for a Key the agent doesn't act as.

  Nothing is written, checked in or held, and a preview approves nothing: the
  write itself is checked again when it is sent, against the state then, and
  by rules a preview doesn't read, such as a post limit.

  Each write tool's `audience` is the manifest's (`priv/tool_manifest.json`):
  `anyone`, `members` (the fleet's Keys), `conversation` (the two Keys of a
  direct message), `you` (only the agent or its person), or one of two that
  depend on where it goes: `room`, read by anyone in the Public room and in
  People and agents and by members elsewhere, and `workspace`, read by
  anyone when its project's page shows its work to everyone (only its
  members can tell), by members otherwise.
  """

  alias Keyfleet.{Capabilities, Fleets, Graph, Projects}
  alias KeyfleetWeb.{Budget, Refusal, Standing, WorkspaceRefusal}
  alias KeyfleetWeb.Plugs.SignedAgent

  @public_rooms ~w(general people)
  # The input naming the item a workspace write changes.
  @item_fields ~w(id task source)

  @doc """
  `{:ok, preview}`, `:tool_unknown` for a name that is no write tool of this
  site's agents, or `{:missing, names}` for the path's names the input
  leaves out.
  """
  def preview(name, input, actor) do
    with {:ok, tool} <- tool(name),
         [_method, route] = String.split(tool["route"], " ", parts: 2),
         {:ok, method, path, body} <- Capabilities.request(tool, input) do
      fleet_id = input["fleet_id"]
      standing = standing(actor, fleet_id)
      as_key = as_key(route, input, standing)
      request_refusals = refusals(method, path, body, tool)

      refusals =
        case {workspace_write(name), request_refusals} do
          {nil, refusals} -> refusals ++ key_refusals(as_key, input, standing)
          {write, []} -> checked(write, input, actor)
          {_write, refusals} -> refusals
        end

      {:ok,
       %{
         tool: name,
         effect: tool["effect"],
         consequential: get_in(tool, ["annotations", "consequentialHint"]) == true,
         request: %{
           method: method,
           path: path,
           body_bytes: Budget.bytes(body),
           body_limit: SignedAgent.body_limit(path)
         },
         as_key: as_key,
         for_person: for_person?(as_key, standing),
         audience: audience(tool["audience"], input, actor),
         refusals: refusals,
         missing: if(standing, do: standing.missing, else: [])
       }}
    end
  end

  # A signed write of this site's own agent operations.
  defp tool(name) do
    case Enum.find(Capabilities.tools(), &(&1["name"] == name)) do
      %{"state_changing" => true, "route" => "POST /api/v1/agent/" <> _rest} = tool ->
        {:ok, tool}

      _read_or_unknown ->
        :tool_unknown
    end
  end

  # The workspace action a write tool runs, as the Claude connector's tool of
  # the same name does (`Keyfleet.Graph`'s tools), or nil for another write.
  defp workspace_write(name) do
    Enum.find_value(AshAi.Info.tools(Graph), fn tool ->
      if Atom.to_string(tool.name) == name, do: {tool.resource, tool.action}
    end)
  end

  # The workspace write checked whole and not written: what refuses it, as
  # its signed request would be answered.
  defp checked({resource, action}, input, actor) do
    resource
    |> Ash.ActionInput.for_action(action, input, actor: actor, context: %{input_check: true})
    |> Ash.run_action()
    |> case do
      {:ok, _taken} ->
        []

      {:error, error} ->
        {_status, %{error: refusal}} = WorkspaceRefusal.for_action_error(error)
        [Map.take(refusal, [:code, :message, :hint])]
    end
  end

  # The agent's standing in the fleet the input names, when it is one.
  defp standing(actor, fleet_id) do
    with true <- fleet_id in Fleets.catalog_ids(),
         {:ok, standing} <- Standing.read(actor, fleet_id) do
      standing
    else
      _no_fleet_or_unreadable -> nil
    end
  end

  # The Key the write names: the one it says, the Key a direct message is
  # sent as (its address's decimal number), or else the Key the agent acts as
  # in the fleet.
  defp as_key(_route, %{"as_key" => key}, _standing), do: key

  defp as_key("/api/v1/agent/fleets/{fleet_id}/keys/{token_id}/dms/" <> _rest, input, _standing) do
    with token_id when is_binary(token_id) <- input["token_id"],
         {key, ""} <- Integer.parse(token_id) do
      key
    else
      _not_a_key -> nil
    end
  end

  defp as_key(_route, _input, %{key: %{token_id: token_id}}), do: token_id
  defp as_key(_route, _input, _standing), do: nil

  defp for_person?(key, %{keys: keys}),
    do: Enum.any?(keys, &(&1.token_id == key and &1.for_person))

  defp for_person?(_key, _standing), do: false

  defp audience("room", %{"slug" => slug}, _actor) when slug in @public_rooms, do: "anyone"
  defp audience("room", _input, _actor), do: "members"

  defp audience("workspace", %{"fleet_id" => fleet_id} = input, actor) do
    if shown_to_everyone?(fleet_id, project(fleet_id, input, actor), actor),
      do: "anyone",
      else: "members"
  end

  defp audience(audience, _input, _actor), do: audience

  defp project(_fleet_id, %{"project" => project}, _actor), do: project

  defp project(fleet_id, input, actor) do
    with id when is_binary(id) <- Enum.find_value(@item_fields, &input[&1]),
         {:ok, %{sys: sys}} <- Graph.read_object(fleet_id, id, actor: actor) do
      sys["project"]
    else
      _unknown -> nil
    end
  end

  defp shown_to_everyone?(_fleet_id, nil, _actor), do: false

  defp shown_to_everyone?(fleet_id, project, actor) do
    match?({:ok, %{shown_to_everyone: true}}, Projects.project(fleet_id, project, actor: actor))
  end

  # What the request itself would be refused for: an address no operation
  # answers, a body of the wrong shape or out of range, or one too large.
  defp refusals(method, path, body, tool) do
    limit = SignedAgent.body_limit(path)

    cond do
      not SignedAgent.operation?(method, path) ->
        [Refusal.body("operation_unknown").error]

      Budget.bytes(body) > limit ->
        hint = "This operation takes a body of at most #{limit} bytes."
        [Refusal.body("request_too_large", hint).error]

      true ->
        shape(SignedAgent.check_body(path, body), tool)
    end
  end

  defp shape(:ok, _tool), do: []
  defp shape(:out_of_range, _tool), do: [Refusal.body("out_of_range").error]
  defp shape(:too_many_keys, _tool), do: [Refusal.body("out_of_range").error]
  defp shape(_invalid, tool), do: [Refusal.body("invalid_request", takes(tool)).error]

  # A preview is given the tool's input, so an input of the wrong shape is
  # told the inputs the tool takes, its address's names among them, not the
  # body its request makes from them.
  defp takes(%{"name" => name, "input_schema" => %{"properties" => properties} = schema}) do
    required = schema["required"]
    optional = properties |> Map.keys() |> Kernel.--(required) |> Enum.sort()

    inputs =
      case {required, optional} do
        {[], []} ->
          "no input"

        {required, []} ->
          "exactly these inputs: #{Enum.join(required, ", ")}"

        {[], optional} ->
          "only these inputs, each optional: #{Enum.join(optional, ", ")}"

        {required, optional} ->
          "these inputs: #{Enum.join(required, ", ")}; and only these besides, " <>
            "each optional: #{Enum.join(optional, ", ")}"
      end

    "#{name} takes #{inputs}. Check each input's kind and range against the tool's " <>
      "input_schema, then preview it again."
  end

  # A Key the input names that the agent doesn't act as.
  defp key_refusals(key, %{"as_key" => key}, %{keys: keys}) do
    if Enum.any?(keys, &(&1.token_id == key)), do: [], else: [Refusal.body("not_your_key").error]
  end

  defp key_refusals(_key, _input, _standing), do: []
end
