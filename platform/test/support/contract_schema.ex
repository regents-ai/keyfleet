defmodule KeyFleet.ContractSchema do
  @moduledoc """
  Checks an answer against a schema of the API contract, so a test can show
  that what the server really sends is what the contract promises.

  It knows the keywords the contract uses and nothing more: a schema that
  uses any other keyword that constrains a value is refused rather than
  passed unchecked.
  """

  @contract Path.expand("../../contracts/api-contract.openapiv3.yaml", __DIR__)
  @prefix "#/components/schemas/"
  @notes ~w(description default)

  @doc """
  Answers the ways `value` breaks the contract schema called `name`, as
  readable lines; an empty list when it fits.
  """
  @spec errors(term(), String.t()) :: [String.t()]
  def errors(value, name) do
    schemas = YamlElixir.read_from_file!(@contract)["components"]["schemas"]
    json = value |> Jason.encode!() |> Jason.decode!()
    check(json, %{"$ref" => @prefix <> name}, schemas, "$")
  end

  defp check(value, schema, schemas, at) do
    schema
    |> Map.drop(@notes)
    |> Enum.flat_map(fn {keyword, rule} -> rule(keyword, rule, value, schema, schemas, at) end)
  end

  defp rule("$ref", @prefix <> name, value, _schema, schemas, at),
    do: check(value, Map.fetch!(schemas, name), schemas, at)

  defp rule("oneOf", choices, value, _schema, schemas, at) do
    case Enum.count(choices, &(check(value, &1, schemas, at) == [])) do
      1 -> []
      matched -> ["#{at}: fits #{matched} of the #{length(choices)} choices, not exactly one"]
    end
  end

  defp rule("type", types, value, _schema, _schemas, at) do
    if Enum.any?(List.wrap(types), &type?(&1, value)),
      do: [],
      else: ["#{at}: is not of type #{inspect(types)}"]
  end

  defp rule("enum", allowed, value, _schema, _schemas, at),
    do: if(value in allowed, do: [], else: ["#{at}: #{inspect(value)} is not one of the allowed"])

  defp rule("const", expected, value, _schema, _schemas, at),
    do: if(value == expected, do: [], else: ["#{at}: is not #{inspect(expected)}"])

  defp rule("minimum", min, value, _schema, _schemas, at),
    do: bound(is_number(value) and value < min, at, "is below #{min}")

  defp rule("maximum", max, value, _schema, _schemas, at),
    do: bound(is_number(value) and value > max, at, "is above #{max}")

  defp rule("minLength", min, value, _schema, _schemas, at),
    do: bound(is_binary(value) and characters(value) < min, at, "is shorter than #{min}")

  defp rule("maxLength", max, value, _schema, _schemas, at),
    do: bound(is_binary(value) and characters(value) > max, at, "is longer than #{max}")

  defp rule("pattern", pattern, value, _schema, _schemas, at),
    do:
      bound(
        is_binary(value) and not (pattern |> Regex.compile!() |> Regex.match?(value)),
        at,
        "does not match #{pattern}"
      )

  defp rule("maxItems", max, value, _schema, _schemas, at),
    do: bound(is_list(value) and length(value) > max, at, "has more than #{max} items")

  defp rule("items", _item, value, _schema, _schemas, _at) when not is_list(value), do: []

  defp rule("items", item, value, _schema, schemas, at) do
    value
    |> Enum.with_index()
    |> Enum.flat_map(fn {element, index} -> check(element, item, schemas, "#{at}[#{index}]") end)
  end

  defp rule(keyword, _rule, value, _schema, _schemas, _at)
       when keyword in ~w(required properties additionalProperties) and not is_map(value),
       do: []

  defp rule("required", names, value, _schema, _schemas, at),
    do: for(name <- names, not Map.has_key?(value, name), do: "#{at}: lacks #{name}")

  defp rule("properties", properties, value, _schema, schemas, at) do
    Enum.flat_map(properties, fn {name, property} ->
      case value do
        %{^name => field} -> check(field, property, schemas, "#{at}.#{name}")
        _absent -> []
      end
    end)
  end

  defp rule("additionalProperties", false, value, schema, _schemas, at) do
    known = Map.get(schema, "properties", %{})
    for name <- Map.keys(value), not Map.has_key?(known, name), do: "#{at}: has #{name}"
  end

  defp rule(keyword, rule, _value, _schema, _schemas, at),
    do: raise(ArgumentError, "#{at}: this check does not know #{keyword}: #{inspect(rule)}")

  defp type?("object", value), do: is_map(value)
  defp type?("array", value), do: is_list(value)
  defp type?("string", value), do: is_binary(value)
  defp type?("integer", value), do: is_integer(value)
  defp type?("boolean", value), do: is_boolean(value)
  defp type?("null", value), do: is_nil(value)

  defp bound(true, at, broken), do: ["#{at}: #{broken}"]
  defp bound(false, _at, _broken), do: []

  # JSON counts a string's length in characters, not graphemes or bytes.
  defp characters(string), do: string |> String.to_charlist() |> length()
end
