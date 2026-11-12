# SPDX-FileCopyrightText: 2026 ash_rest contributors
#
# SPDX-License-Identifier: MIT

defmodule AshRest.Fields do
  @moduledoc """
  Builds the `fields` selection ash_rpc needs from the decorated manifest.

  ash_rpc requires an explicit, non-empty `fields` list for reads and for typed
  generic returns, and rejects embedded resources, unions and typed maps that
  are requested without a nested selection. REST clients don't send a selection
  (sparse fieldsets are not supported in v1), so this module selects every field
  the manifest marks `select_by_default?`, recursing into embedded resources,
  typed maps/structs/tuples and every union member, using the wire (client)
  names of the decorated manifest.

  Alongside the selection it returns a *shape*: the resource behind each level
  of the response and its included relationships, so `AshRest.Response` can add
  `"type"` to every record and honour `include_nil_values?`.
  """

  alias Ash.Info.Manifest
  alias AshRest.Resource.Info
  alias AshRpc.Manifest.Custom

  @typedoc "What `AshRest.Response` needs to know about the records at one level of the output."
  @type shape :: %{
          resource: module(),
          type: String.t() | nil,
          include_nil?: boolean(),
          children: %{String.t() => shape()}
        }

  @type field :: String.t() | %{String.t() => term()}

  @doc """
  The default selection of `resource` plus one nested selection per relationship
  in `include` (a keyword tree such as `[author: [], comments: [author: []]]`).
  """
  @spec selection(Manifest.t(), module(), keyword()) :: {[field()], shape()}
  def selection(manifest, resource, include \\ []) do
    res = manifest_resource!(manifest, resource)
    base = resource_fields(manifest, res, [resource])

    {envelopes, children} =
      include
      |> Enum.map(fn {rel, sub_include} ->
        relationship = Map.fetch!(res.relationships, rel)
        {sub_fields, sub_shape} = selection(manifest, relationship.destination, sub_include)
        client = client_name(res, rel)
        {%{client => sub_fields}, {client, sub_shape}}
      end)
      |> Enum.unzip()

    {base ++ envelopes, shape(resource, Map.new(children))}
  end

  @doc """
  The selection for a `related` route: the parent's primary key plus the
  relationship with the destination's default fields and, for to-many
  relationships, the `page`/`filter`/`sort` query options in an envelope.

  Returns the fields, the relationship's wire name, its cardinality and the
  shape of the destination records.
  """
  @spec related_selection(Manifest.t(), module(), atom(), keyword(), map()) ::
          {[field()], String.t(), :one | :many, shape()}
  def related_selection(manifest, resource, relationship, include, query_opts) do
    res = manifest_resource!(manifest, resource)
    rel = Map.fetch!(res.relationships, relationship)
    {dest_fields, dest_shape} = selection(manifest, rel.destination, include)
    client = client_name(res, relationship)

    nested =
      case rel.cardinality do
        :many ->
          query_opts
          |> Enum.reject(fn {_key, value} -> is_nil(value) end)
          |> Map.new(fn {key, value} -> {to_string(key), value} end)
          |> Map.put("fields", dest_fields)

        :one ->
          dest_fields
      end

    pk = Info.primary_key(resource)
    {[client_name(res, pk), %{client => nested}], client, rel.cardinality, dest_shape}
  end

  @doc """
  The selection a generic action's return value needs, or `nil` when ash_rpc
  takes none (primitives, untyped maps, no return value).

  Resource returns get the resource's default fields plus `include`; typed maps,
  structs, tuples and unions get their nested selection.
  """
  @spec return_selection(Manifest.t(), Manifest.Action.t(), keyword()) ::
          {[field()] | nil, shape() | nil}
  def return_selection(_manifest, %Manifest.Action{returns: nil}, _include), do: {nil, nil}

  def return_selection(manifest, %Manifest.Action{returns: type}, include) do
    case resource_module(manifest, type) do
      nil ->
        case type_selection(manifest, type, []) do
          {:nested, fields} -> {fields, nil}
          _ -> {nil, nil}
        end

      resource ->
        {fields, shape} = selection(manifest, resource, include)
        {fields, shape}
    end
  end

  @doc "The resource module a type (or array of it) refers to, if it is an exposed resource."
  @spec resource_module(Manifest.t(), Manifest.Type.t() | nil) :: module() | nil
  def resource_module(manifest, %Manifest.Type{kind: :array, item_type: item}),
    do: resource_module(manifest, item)

  def resource_module(manifest, %Manifest.Type{kind: :type_ref, module: module}),
    do: resource_module(manifest, AshRpc.Manifest.type_lookup(manifest)[module])

  def resource_module(manifest, %Manifest.Type{kind: kind} = type)
      when kind in [:resource, :embedded_resource, :struct, :map] do
    module = Manifest.Type.effective_resource(type)

    if ash_resource?(module) and AshRest.Manifest.resource(manifest, module) != nil,
      do: module,
      else: nil
  end

  def resource_module(_manifest, _type), do: nil

  @doc "The wire name of `field` on the manifest resource."
  @spec client_name(Manifest.Resource.t(), atom()) :: String.t()
  def client_name(%Manifest.Resource{} = res, field),
    do: Map.get(Custom.field_names(res), field, to_string(field))

  @doc "The shape of `resource` records with the given included children."
  @spec shape(module(), %{String.t() => shape()}) :: shape()
  def shape(resource, children \\ %{}) do
    rest? = Info.rest_extension?(resource)

    %{
      resource: resource,
      type: if(rest?, do: Info.type(resource)),
      include_nil?: if(rest?, do: Info.include_nil_values?(resource), else: true),
      children: children
    }
  end

  # -- default fields of a resource ------------------------------------------

  defp resource_fields(manifest, %Manifest.Resource{} = res, seen) do
    res.fields
    |> Enum.filter(fn {_name, field} -> field.select_by_default? end)
    |> Enum.sort_by(fn {name, _} -> client_name(res, name) end)
    |> Enum.flat_map(fn {name, field} ->
      client = client_name(res, name)

      case field_selection(manifest, field, seen) do
        :scalar -> [client]
        {:nested, nested} -> [%{client => nested}]
        {:args, args} -> [%{client => args}]
        :skip -> []
      end
    end)
  end

  defp field_selection(
         manifest,
         %Manifest.Field{kind: :calculation, arguments: [_ | _] = args} = f,
         seen
       ) do
    if Enum.any?(args, &required_argument?/1) do
      :skip
    else
      case type_selection(manifest, f.type, seen) do
        :skip -> :skip
        :scalar -> {:args, %{"args" => %{}}}
        {:nested, nested} -> {:args, %{"args" => %{}, "fields" => nested}}
      end
    end
  end

  defp field_selection(manifest, %Manifest.Field{type: type}, seen),
    do: type_selection(manifest, type, seen)

  # Ash.Info.Manifest.Argument documents `required?` as the optionality flag.
  defp required_argument?(%Manifest.Argument{required?: required?}), do: required? == true

  # :scalar, {:nested, fields} or :skip (a type ash_rpc can't select by default,
  # or a recursive embedded resource).
  defp type_selection(_manifest, nil, _seen), do: :scalar

  defp type_selection(manifest, %Manifest.Type{kind: :array, item_type: item}, seen),
    do: type_selection(manifest, item, seen)

  defp type_selection(manifest, %Manifest.Type{kind: :type_ref, module: module}, seen) do
    case AshRpc.Manifest.type_lookup(manifest)[module] do
      nil -> :scalar
      type -> type_selection(manifest, type, seen)
    end
  end

  defp type_selection(manifest, %Manifest.Type{kind: :union} = type, seen) do
    member_names = Custom.type_member_names(type)

    members =
      Enum.flat_map(type.members || [], fn member ->
        client = Map.get(member_names, member.name, to_string(member.name))

        case type_selection(manifest, member.type, seen) do
          :scalar -> [client]
          {:nested, nested} -> [%{client => nested}]
          :skip -> []
        end
      end)

    if members == [], do: :skip, else: {:nested, members}
  end

  defp type_selection(manifest, %Manifest.Type{kind: kind} = type, seen)
       when kind in [:resource, :embedded_resource, :struct, :map, :keyword, :tuple] do
    module = Manifest.Type.effective_resource(type)

    cond do
      kind in [:resource, :embedded_resource, :struct, :map] and ash_resource?(module) ->
        embedded_selection(manifest, module, seen)

      Manifest.Type.has_fields?(type) ->
        typed_selection(manifest, type, seen)

      true ->
        :scalar
    end
  end

  defp type_selection(_manifest, _type, _seen), do: :scalar

  defp embedded_selection(manifest, module, seen) do
    res = AshRest.Manifest.resource(manifest, module)

    cond do
      is_nil(res) -> :skip
      module in seen -> :skip
      true -> {:nested, resource_fields(manifest, res, [module | seen])}
    end
  end

  defp typed_selection(manifest, type, seen) do
    names = Custom.type_field_names(type)

    fields =
      (type.fields || type.element_types || [])
      |> Enum.flat_map(fn
        %{name: name, type: field_type} ->
          client = Map.get(names, name, to_string(name))

          case type_selection(manifest, field_type, seen) do
            :scalar -> [client]
            {:nested, nested} -> [%{client => nested}]
            :skip -> []
          end

        _ ->
          []
      end)

    if fields == [], do: :scalar, else: {:nested, fields}
  end

  defp manifest_resource!(manifest, resource) do
    AshRest.Manifest.resource(manifest, resource) ||
      raise ArgumentError, "#{inspect(resource)} is not in the manifest"
  end

  defp ash_resource?(module) when is_atom(module) and not is_nil(module) do
    Code.ensure_loaded?(module) and Spark.Dsl.is?(module, Ash.Resource)
  end

  defp ash_resource?(_), do: false
end
