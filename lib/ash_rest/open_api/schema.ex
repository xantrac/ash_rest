# SPDX-FileCopyrightText: 2026 ash_rest contributors
#
# SPDX-License-Identifier: MIT

defmodule AshRest.OpenApi.Schema do
  @moduledoc """
  JSON Schema 2020-12 for the values AshRest puts on the wire.

  Builds schema maps (string keys) from `Ash.Info.Manifest.Type` structs and
  manifest resources, following the encodings of ash_rpc's output formatter:
  dates and datetimes are ISO 8601 strings, decimals are strings, atoms and
  enums are strings, unions are single-key `{"member": value}` objects,
  embedded resources, typed maps, keywords and tuples are objects.

  A `%AshRest.OpenApi.Schema{}` is a registry of named component schemas.
  Anything with a name (exposed resources, embedded resources, named types,
  list wrappers, filter objects) is registered once and referenced with
  `$ref`; a component under construction is already registered, so
  recursive types terminate.

  Nullability is expressed as `"type": [t, "null"]` or `anyOf` with
  `{"type": "null"}`, never with `nullable`.
  """

  alias Ash.Info.Manifest
  alias Ash.Info.Manifest.Generator.TypeResolver
  alias Ash.Info.Manifest.Type
  alias AshRest.Resource.Info
  alias AshRpc.Introspection
  alias AshRpc.Manifest.Custom

  defstruct manifest: nil, resource_lookup: %{}, type_lookup: %{}, schemas: %{}, names: %{}

  @type t :: %__MODULE__{
          manifest: Manifest.t(),
          resource_lookup: %{module() => Manifest.Resource.t()},
          type_lookup: %{module() => Type.t()},
          schemas: %{String.t() => map()},
          names: %{String.t() => term()}
        }

  @type schema :: map()
  @type direction :: :input | :output

  @doc "A new, empty registry over a decorated manifest."
  @spec new(Manifest.t()) :: t()
  def new(manifest) do
    %__MODULE__{
      manifest: manifest,
      resource_lookup: AshRpc.Manifest.resource_lookup(manifest),
      type_lookup: AshRpc.Manifest.type_lookup(manifest)
    }
  end

  @doc "The registered component schemas, keyed by name."
  @spec schemas(t()) :: %{String.t() => schema()}
  def schemas(%__MODULE__{schemas: schemas}), do: schemas

  @doc "A `$ref` to the component schema `name`."
  @spec ref(String.t()) :: schema()
  def ref(name), do: %{"$ref" => "#/components/schemas/#{name}"}

  @doc """
  Makes `schema` accept `null`.

  A schema with a single `type` gets `"null"` added to it (and to `enum`
  when present); anything else is wrapped in `anyOf`.
  """
  @spec nullable(schema()) :: schema()
  def nullable(%{"type" => type} = schema)
      when is_binary(type) and not is_map_key(schema, "$ref") do
    schema
    |> Map.put("type", [type, "null"])
    |> then(fn
      %{"enum" => values} = s -> Map.put(s, "enum", values ++ [nil])
      s -> s
    end)
  end

  def nullable(%{"type" => types} = schema) when is_list(types) do
    if "null" in types, do: schema, else: Map.put(schema, "type", types ++ ["null"])
  end

  def nullable(%{"anyOf" => alternatives} = schema) do
    if %{"type" => "null"} in alternatives,
      do: schema,
      else: Map.put(schema, "anyOf", alternatives ++ [%{"type" => "null"}])
  end

  def nullable(schema) when schema == %{}, do: schema
  def nullable(schema), do: %{"anyOf" => [schema, %{"type" => "null"}]}

  @doc "The component name of an exposed (`AshRest`) resource: `Post` for the rest type `post`."
  @spec resource_name(t(), module()) :: String.t()
  def resource_name(reg, module), do: component_name(reg, {:resource, module}, type_name(module))

  @doc "Registers the record schema of an exposed resource and returns a `$ref` to it."
  @spec resource(t(), module()) :: {schema(), t()}
  def resource(reg, module) do
    component(reg, {:resource, module}, type_name(module), fn reg ->
      resource_schema(reg, module)
    end)
  end

  @doc """
  Registers the list wrapper of an exposed resource and returns a `$ref`.

  With `paginated?: true` (the default) it is `<Name>List`, the envelope of a
  route that can answer with a page: `data` always, `has_more`/`count` and
  `limit`/`offset` (offset pagination) or `next_cursor`/`prev_cursor` (keyset
  pagination) when the request was paginated, `meta` when non-empty.

  With `paginated?: false` it is `<Name>UnpaginatedList`, the envelope of a
  route that never pages (`paginate? false`, or an action without
  pagination): `data` and, when non-empty, `meta`; nothing else.
  """
  @spec list(t(), module(), paginated?: boolean()) :: {schema(), t()}
  def list(reg, module, opts \\ []) do
    if Keyword.get(opts, :paginated?, true),
      do: paginated_list(reg, module),
      else: unpaginated_list(reg, module)
  end

  defp unpaginated_list(reg, module) do
    name = resource_name(reg, module) <> "UnpaginatedList"

    component(reg, {:unpaginated_list, module}, name, fn reg ->
      {item, reg} = resource(reg, module)

      schema = %{
        "type" => "object",
        "description" => "An unpaginated list of #{type_string(module)} records.",
        "required" => ["data"],
        "properties" => %{
          "data" => %{"type" => "array", "items" => item},
          "meta" => %{"type" => "object", "description" => "Action metadata, when non-empty."}
        },
        "additionalProperties" => false
      }

      {schema, reg}
    end)
  end

  defp paginated_list(reg, module) do
    name = resource_name(reg, module) <> "List"

    component(reg, {:list, module}, name, fn reg ->
      {item, reg} = resource(reg, module)

      schema = %{
        "type" => "object",
        "description" => "A page or list of #{type_string(module)} records.",
        "required" => ["data"],
        "properties" => %{
          "data" => %{"type" => "array", "items" => item},
          "has_more" => %{
            "type" => "boolean",
            "description" => "Whether more records exist beyond this page."
          },
          "count" => %{
            "type" => ["integer", "null"],
            "description" => "Total number of records when `page[count]=true` was requested."
          },
          "limit" => %{
            "type" => ["integer", "null"],
            "description" => "Offset pagination: the page size."
          },
          "offset" => %{
            "type" => ["integer", "null"],
            "description" => "Offset pagination: the offset of the first record."
          },
          "next_cursor" => %{
            "type" => ["string", "null"],
            "description" => "Keyset pagination: pass as `page[after]` to fetch the next page."
          },
          "prev_cursor" => %{
            "type" => ["string", "null"],
            "description" =>
              "Keyset pagination: pass as `page[before]` to fetch the previous page."
          },
          "meta" => %{"type" => "object", "description" => "Action metadata, when non-empty."}
        }
      }

      {schema, reg}
    end)
  end

  @doc """
  Registers the `<Name>Filter` schema of an exposed resource and returns a `$ref`.

  One property per filterable field: either a bare value (equality) or an
  object of operators, each typed by its right-hand side. Every operator name
  the runtime accepts is listed (`eq` and `equals`, `gt` and `greater_than`,
  `contains`, ...), restricted the way ash_rpc restricts them: fields holding
  records take `is_nil` only, structured values (maps, unions, ...) take no
  ordering operator. To-one relationships to exposed resources nest the
  destination's filter; `and`, `or` and `not` combine filters.
  """
  @spec filter(t(), module()) :: {schema(), t()}
  def filter(reg, module) do
    name = resource_name(reg, module) <> "Filter"

    component(reg, {:filter, module}, name, fn reg ->
      res = Map.fetch!(reg.resource_lookup, module)
      names = Custom.field_names(res)
      operator_names = operator_client_names(reg.manifest)

      {field_props, reg} =
        res
        |> Manifest.Resource.all_fields()
        |> Enum.filter(& &1.filterable?)
        |> Enum.reduce({%{}, reg}, fn field, {props, reg} ->
          {schema, reg} = field_filter(reg, field, operator_names)
          {Map.put(props, client_name(names, field.name), schema), reg}
        end)

      # Query parameter schemas must not reference themselves, even indirectly:
      # OpenAPI tooling that derives a parameter's shape by following `$ref`s
      # (oaskit's request builder, for one) does not terminate on cycles. So
      # related filters and connectives are described, not referenced.
      rel_props =
        res
        |> Manifest.Resource.all_relationships()
        |> Enum.filter(
          &(&1.filterable? and &1.cardinality == :one and exposed?(reg, &1.destination))
        )
        |> Map.new(fn rel ->
          {client_name(names, rel.name),
           %{
             "type" => "object",
             "description" =>
               "Conditions on the related #{type_string(rel.destination)} " <>
                 "(shape of `#{resource_name(reg, rel.destination)}Filter`)."
           }}
        end)

      nested = "A nested filter with the same shape as `#{name}`."

      indexed =
        " In a query string, index the list: `filter[or][0][title]=A&filter[or][1][title]=B`."

      connectives = %{
        "and" => %{
          "type" => "array",
          "items" => %{"type" => "object", "description" => nested},
          "description" => "All of the nested filters must match." <> indexed
        },
        "or" => %{
          "type" => "array",
          "items" => %{"type" => "object", "description" => nested},
          "description" => "At least one of the nested filters must match." <> indexed
        },
        "not" => %{"type" => "object", "description" => "Negates the nested filter. " <> nested}
      }

      schema = %{
        "type" => "object",
        "description" =>
          "Filter for #{type_string(module)} records. A bare value means equality; " <>
            "an object selects an operator, e.g. `filter[title][eq]=x`.",
        "properties" => field_props |> Map.merge(rel_props) |> Map.merge(connectives)
      }

      {schema, reg}
    end)
  end

  defp field_filter(reg, %Manifest.Field{} = field, operator_names) do
    {value, reg} = type(reg, field.type, :input)

    {ops, reg} =
      (List.wrap(field.filter_operators) ++ List.wrap(field.filter_functions))
      |> Enum.filter(&Introspection.filter_operator_allowed?(field.type, &1.name, reg))
      |> Enum.reduce({%{}, reg}, fn op, {ops, reg} ->
        {rhs, reg} = rhs_schema(reg, op.rhs, field.type)

        ops =
          operator_names
          |> Map.get(op.name, [to_string(op.name)])
          |> Enum.reduce(ops, &Map.put(&2, &1, rhs))

        {ops, reg}
      end)

    operators = %{"type" => "object", "properties" => ops, "additionalProperties" => false}
    {%{"anyOf" => [value, operators]}, reg}
  end

  defp rhs_schema(reg, :same, type), do: type(reg, type, :input)
  defp rhs_schema(reg, :any, _type), do: {%{}, reg}

  defp rhs_schema(reg, {:concrete, module}, _type) do
    type(reg, TypeResolver.resolve(module, []), :input)
  end

  defp rhs_schema(reg, {:array, rhs}, type) do
    {items, reg} = rhs_schema(reg, rhs, type)
    {%{"type" => "array", "items" => items}, reg}
  end

  defp rhs_schema(reg, _rhs, _type), do: {%{}, reg}

  # `%{:== => ["eq", "equals"], :> => ["greater_than", "gt"], :contains => ["contains"], ...}`:
  # every client spelling of each manifest operator or function name.
  #
  # The client names come from ash_rpc's `filter_ops` vocabulary (the keys a
  # filter may use); each resolves to its operator through
  # `Ash.Filter.get_operator/1`, as `AshRpc.FilterInput` does, so `gt` and
  # `greater_than` both land on `:>`. A function keeps its own name. Without a
  # decorated vocabulary, the manifest's first alias (or the name) is used.
  defp operator_client_names(%Manifest{} = manifest) do
    fallback =
      case manifest.filter_capabilities do
        %{operators: operators} when is_list(operators) ->
          Map.new(operators, fn op ->
            {op.name,
             [op.aliases |> List.wrap() |> List.first() |> then(&to_string(&1 || op.name))]}
          end)

        _ ->
          %{}
      end

    manifest
    |> vocabulary(:filter_ops)
    |> Enum.reject(fn {_client, name} -> name in [:and, :or, :not, :input] end)
    |> Enum.reduce(%{}, fn {client, name}, acc ->
      manifest_name =
        case Ash.Filter.get_operator(name) do
          nil -> name
          module -> module.operator()
        end

      Map.update(acc, manifest_name, [client], &[client | &1])
    end)
    |> Map.new(fn {name, clients} -> {name, Enum.sort(clients)} end)
    |> then(&Map.merge(fallback, &1))
  end

  defp vocabulary(manifest, scope) do
    case manifest.custom do
      %{ash_rpc: %{vocabulary: %{^scope => names}}} when is_map(names) -> names
      _ -> %{}
    end
  end

  @doc """
  The JSON Schema of a manifest type.

  `direction` is `:output` for responses and `:input` for request bodies and
  query parameters; the two only differ for decimals (strings out, numbers or
  strings in). Returns the schema and the registry with any components it
  needed.
  """
  @spec type(t(), Type.t() | nil, direction()) :: {schema(), t()}
  def type(reg, type, direction \\ :output)

  def type(reg, nil, _direction), do: {%{}, reg}

  def type(reg, %Type{kind: kind}, _direction)
      when kind in [:string, :ci_string, :atom, :binary],
      do: {%{"type" => "string"}, reg}

  def type(reg, %Type{kind: :uuid}, _direction),
    do: {%{"type" => "string", "format" => "uuid"}, reg}

  def type(reg, %Type{kind: :date}, _direction),
    do: {%{"type" => "string", "format" => "date"}, reg}

  def type(reg, %Type{kind: kind}, _direction) when kind in [:time, :time_usec],
    do: {%{"type" => "string", "format" => "time"}, reg}

  def type(reg, %Type{kind: kind}, _direction)
      when kind in [:datetime, :utc_datetime, :utc_datetime_usec],
      do: {%{"type" => "string", "format" => "date-time"}, reg}

  def type(reg, %Type{kind: :naive_datetime}, _direction),
    do: {%{"type" => "string", "description" => "ISO 8601 datetime without offset"}, reg}

  def type(reg, %Type{kind: :duration}, _direction),
    do: {%{"type" => "string", "description" => "ISO 8601 duration"}, reg}

  def type(reg, %Type{kind: :integer}, _direction), do: {%{"type" => "integer"}, reg}
  def type(reg, %Type{kind: :float}, _direction), do: {%{"type" => "number"}, reg}
  def type(reg, %Type{kind: :boolean}, _direction), do: {%{"type" => "boolean"}, reg}

  def type(reg, %Type{kind: :decimal}, :output),
    do: {%{"type" => "string", "description" => "Decimal number as a string"}, reg}

  def type(reg, %Type{kind: :decimal}, :input),
    do: {%{"type" => ["number", "string"], "description" => "Decimal number"}, reg}

  def type(reg, %Type{kind: :enum, values: values}, _direction) when is_list(values),
    do: {%{"type" => "string", "enum" => Enum.map(values, &to_string/1)}, reg}

  def type(reg, %Type{kind: :enum}, _direction), do: {%{"type" => "string"}, reg}

  def type(reg, %Type{kind: :array, item_type: item_type}, direction) do
    {items, reg} = type(reg, item_type, direction)
    {%{"type" => "array", "items" => items}, reg}
  end

  def type(reg, %Type{kind: :union} = union, direction) do
    names = Custom.type_member_names(union)

    {members, reg} =
      Enum.map_reduce(union.members || [], reg, fn member, reg ->
        {schema, reg} = type(reg, member.type, direction)
        name = client_name(names, member.name)

        schema = %{
          "type" => "object",
          "properties" => %{name => schema},
          "required" => [name],
          "additionalProperties" => false
        }

        {maybe_put(schema, "description", member[:description]), reg}
      end)

    {%{"oneOf" => members}, reg}
  end

  def type(reg, %Type{kind: :embedded_resource} = type, direction) do
    module = Type.effective_resource(type)

    case embedded_definition(reg, type) do
      %Manifest.Resource{} = res ->
        component(reg, {:embedded, module}, res.name || type_name(module), fn reg ->
          embedded_schema(reg, res, direction)
        end)

      nil ->
        {%{"type" => "object"}, reg}
    end
  end

  def type(reg, %Type{kind: :resource} = type, _direction) do
    module = Type.effective_resource(type)
    if exposed?(reg, module), do: resource(reg, module), else: {%{"type" => "object"}, reg}
  end

  def type(reg, %Type{kind: :type_ref, module: module}, direction) do
    case Map.get(reg.type_lookup, module) do
      %Type{kind: :type_ref} ->
        {%{}, reg}

      %Type{} = definition ->
        component(reg, {:type, module}, definition.name || type_name(module), fn reg ->
          type(reg, definition, direction)
        end)

      nil ->
        {%{}, reg}
    end
  end

  def type(reg, %Type{kind: kind} = type, direction)
      when kind in [:map, :struct, :keyword, :tuple] do
    module = Type.effective_module(type)

    cond do
      kind in [:map, :struct] and ash_resource?(module) and exposed?(reg, module) ->
        resource(reg, module)

      kind in [:map, :struct] and ash_resource?(module) and
          match?(%Manifest.Resource{embedded?: true}, Map.get(reg.resource_lookup, module)) ->
        type(
          reg,
          %Type{
            kind: :embedded_resource,
            name: type_name(module),
            module: module,
            resource_module: module
          },
          direction
        )

      Type.has_fields?(type) ->
        fields_schema(reg, type, direction)

      true ->
        {%{"type" => "object"}, reg}
    end
  end

  def type(reg, %Type{}, _direction), do: {%{}, reg}

  # Typed maps, structs, keywords and tuples are objects keyed by field name.
  defp fields_schema(reg, type, direction) do
    names = Custom.type_field_names(type)
    fields = Type.get_fields(type)

    {props, reg} =
      Enum.reduce(fields, {%{}, reg}, fn field, {props, reg} ->
        {schema, reg} = type(reg, field.type, direction)
        schema = if field[:allow_nil?] == false, do: schema, else: nullable(schema)
        schema = maybe_put(schema, "description", field[:description])
        {Map.put(props, client_name(names, field.name), schema), reg}
      end)

    required =
      for field <- fields, field[:allow_nil?] == false, do: client_name(names, field.name)

    schema =
      %{"type" => "object", "properties" => props}
      |> put_required(required)

    {schema, reg}
  end

  defp embedded_definition(reg, %Type{resource: %Manifest.Resource{} = res}) do
    Map.get(reg.resource_lookup, res.module) || res
  end

  defp embedded_definition(reg, type) do
    module = Type.effective_resource(type)

    Map.get(reg.resource_lookup, module) ||
      case Map.get(reg.type_lookup, module) do
        %Type{resource: %Manifest.Resource{} = res} -> res
        _ -> nil
      end
  end

  # An embedded resource is an object of its default-selected fields; it has
  # no `type` discriminator (only exposed resources carry one).
  defp embedded_schema(reg, %Manifest.Resource{} = res, direction) do
    names = Custom.field_names(res)
    fields = default_fields(res)

    {props, reg} =
      Enum.reduce(fields, {%{}, reg}, fn field, {props, reg} ->
        {schema, reg} = field_schema(reg, field, direction)
        {Map.put(props, client_name(names, field.name), schema), reg}
      end)

    schema =
      %{"type" => "object", "properties" => props}
      |> maybe_put("description", res.description)
      |> put_required(required_fields(names, fields))

    {schema, reg}
  end

  # An exposed resource record: `type` discriminator, default-selected
  # fields, and every includable relationship as an optional property.
  defp resource_schema(reg, module) do
    res = Map.fetch!(reg.resource_lookup, module)
    names = Custom.field_names(res)
    rest_type = type_string(module)
    fields = default_fields(res)

    {field_props, reg} =
      Enum.reduce(fields, {%{}, reg}, fn field, {props, reg} ->
        {schema, reg} = field_schema(reg, field, :output)
        {Map.put(props, client_name(names, field.name), schema), reg}
      end)

    {rel_props, reg} =
      res
      |> Manifest.Resource.all_relationships()
      |> Enum.filter(&exposed?(reg, &1.destination))
      |> Enum.reduce({%{}, reg}, fn rel, {props, reg} ->
        {dest, reg} = resource(reg, rel.destination)

        schema =
          case rel.cardinality do
            :many -> %{"type" => "array", "items" => dest}
            :one -> nullable(dest)
          end

        schema =
          schema
          |> Map.put(
            "description",
            rel.description ||
              "The #{rel.name} of this #{rest_type}; present when requested with `include`."
          )

        {Map.put(props, client_name(names, rel.name), schema), reg}
      end)

    required =
      ["type", client_name(names, Info.primary_key(module)) | required_fields(names, fields)]
      |> Enum.uniq()

    schema = %{
      "type" => "object",
      "description" => res.description || "A #{rest_type} record.",
      "required" => required,
      "properties" =>
        %{"type" => %{"const" => rest_type, "description" => "The resource type."}}
        |> Map.merge(field_props)
        |> Map.merge(rel_props)
    }

    {schema, reg}
  end

  # Only non-nullable attributes are always present. Aggregates and
  # calculations may be missing even when declared non-nullable: ash_rpc
  # cannot load them on a record an atomic destroy has already removed, and
  # drops those a policy forbids.
  defp required_fields(names, fields) do
    for %Manifest.Field{kind: :attribute, allow_nil?: false} = f <- fields,
        do: client_name(names, f.name)
  end

  defp field_schema(reg, %Manifest.Field{} = field, direction) do
    {schema, reg} = type(reg, field.type, direction)
    schema = if field.allow_nil?, do: nullable(schema), else: schema
    {maybe_put(schema, "description", field.description), reg}
  end

  @doc """
  The fields of a manifest resource that a response carries by default:
  every `select_by_default?` field, except calculations with required
  arguments (they cannot be selected without input).
  """
  @spec default_fields(Manifest.Resource.t()) :: [Manifest.Field.t()]
  def default_fields(%Manifest.Resource{} = res) do
    res
    |> Manifest.Resource.all_fields()
    |> Enum.filter(fn
      %Manifest.Field{select_by_default?: false} ->
        false

      %Manifest.Field{kind: :calculation, arguments: args} ->
        not Enum.any?(args || [], & &1.required?)

      _ ->
        true
    end)
  end

  @doc "Whether `module` is a resource exposed through `AshRest` and present in the manifest."
  @spec exposed?(t(), module()) :: boolean()
  def exposed?(reg, module) do
    is_atom(module) and Map.has_key?(reg.resource_lookup, module) and
      Info.rest_extension?(module)
  end

  @doc "The client (wire) name of `field`, from a decorated names map."
  @spec client_name(%{atom() => String.t()}, atom()) :: String.t()
  def client_name(names, field), do: Map.get(names, field, to_string(field))

  # -- components -------------------------------------------------------------

  # Registers `name` for `key` (building it with `build` once), returning a ref.
  # The entry is reserved before `build` runs so recursive refs resolve to it.
  defp component(reg, key, preferred, build) do
    name = component_name(reg, key, preferred)

    if Map.has_key?(reg.schemas, name) do
      {ref(name), reg}
    else
      reg = %{
        reg
        | schemas: Map.put(reg.schemas, name, %{"type" => "object"}),
          names: Map.put(reg.names, name, key)
      }

      {schema, reg} = build.(reg)
      {ref(name), %{reg | schemas: Map.put(reg.schemas, name, schema)}}
    end
  end

  # Component names are unique per key; a clash with another key falls back
  # to the full module path.
  defp component_name(reg, key, preferred) do
    case Map.get(reg.names, preferred) do
      nil -> preferred
      ^key -> preferred
      _ -> key |> elem(1) |> inspect() |> String.replace(~r/[^A-Za-z0-9]/, "")
    end
  end

  defp type_name(module) when is_atom(module) do
    if Info.rest_extension?(module) do
      module |> type_string() |> Macro.camelize()
    else
      module |> Module.split() |> List.last()
    end
  end

  defp type_string(module), do: Info.type(module)

  defp ash_resource?(module) when is_atom(module) and not is_nil(module),
    do: Spark.Dsl.is?(module, Ash.Resource)

  defp ash_resource?(_), do: false

  defp put_required(schema, []), do: schema
  defp put_required(schema, required), do: Map.put(schema, "required", required)

  defp maybe_put(schema, _key, nil), do: schema
  defp maybe_put(schema, key, value), do: Map.put(schema, key, value)
end
