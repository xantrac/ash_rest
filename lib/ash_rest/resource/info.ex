# SPDX-FileCopyrightText: 2026 ash_rest contributors
#
# SPDX-License-Identifier: MIT

# Adapted from ash_json_api (MIT), https://github.com/ash-project/ash_json_api
defmodule AshRest.Resource.Info do
  @moduledoc """
  Introspection helpers for resources using the `AshRest` extension.

  Besides the helpers below, `Spark.InfoGenerator` defines `rest_<option>/1` and
  `rest_<option>!/1` for every `rest` option and `rest_routes/1` for the routes.
  """
  use Spark.InfoGenerator, extension: AshRest, sections: [:rest]

  alias AshRest.Resource.Route
  alias Spark.Dsl.Extension

  @type resource :: Ash.Resource.t() | Spark.Dsl.t()

  @doc """
  The type name of the resource, e.g. `"blog_post"`.

  Defaults to the underscored last segment of the module name.
  """
  @spec type(resource()) :: String.t()
  def type(resource) do
    case Extension.get_opt(resource, [:rest], :type, nil) do
      nil ->
        resource
        |> Extension.get_persisted(:module)
        |> AshRest.Resource.Transformers.SetRouteDefaults.default_type()

      type ->
        type
    end
  end

  @doc "The base path of the resource's routes, e.g. `\"/posts\"` (no trailing slash). `nil` without a `rest` section."
  @spec base(resource()) :: String.t() | nil
  def base(resource), do: Extension.get_opt(resource, [:rest], :base, nil)

  @doc "The resource's routes, with defaults applied and `base` prepended to every path."
  @spec routes(resource()) :: [Route.t()]
  def routes(resource), do: Extension.get_entities(resource, [:rest, :routes])

  @doc """
  The includable relationships as a nested keyword list with `[]` leaves.

  `includes [:comments, author: :profile]` returns `[comments: [], author: [profile: []]]`.
  The tree is normalised at compile time.
  """
  @spec includes(resource()) :: keyword()
  def includes(resource), do: Extension.get_opt(resource, [:rest], :includes, [])

  @doc "Field renames as a map of field name to wire name, e.g. `%{inserted_at: \"created_at\"}`."
  @spec field_names(resource()) :: %{atom() => String.t()}
  def field_names(resource) do
    resource
    |> Extension.get_opt([:rest], :field_names, [])
    |> Map.new()
  end

  @doc "Argument renames of `action` as a map of argument name to wire name. `%{}` when none."
  @spec argument_names(resource(), atom()) :: %{atom() => String.t()}
  def argument_names(resource, action) do
    resource
    |> Extension.get_opt([:rest], :argument_names, [])
    |> Keyword.get_values(action)
    |> Enum.concat()
    |> Map.new()
  end

  @doc "Whether fields with `nil` values are included in responses. Defaults to `true`."
  @spec include_nil_values?(resource()) :: boolean()
  def include_nil_values?(resource),
    do: Extension.get_opt(resource, [:rest], :include_nil_values?, true)

  @doc "The OpenAPI tag of the resource's operations. Defaults to `type/1`."
  @spec open_api_tag(resource()) :: String.t()
  def open_api_tag(resource),
    do: Extension.get_opt(resource, [:rest, :open_api], :tag, nil) || type(resource)

  @doc "The description of the resource's OpenAPI tag, or `nil`."
  @spec open_api_tag_description(resource()) :: String.t() | nil
  def open_api_tag_description(resource),
    do: Extension.get_opt(resource, [:rest, :open_api], :tag_description, nil)

  @doc """
  The OpenAPI component schema name of the resource. Defaults to the camelized
  `type/1`, e.g. `"blog_post"` -> `"BlogPost"`.
  """
  @spec open_api_schema_name(resource()) :: String.t()
  def open_api_schema_name(resource) do
    Extension.get_opt(resource, [:rest, :open_api], :schema_name, nil) ||
      resource |> type() |> Macro.camelize()
  end

  @doc """
  The description of the resource's OpenAPI schema: `open_api.description`, else the
  Ash resource `description`, else `nil`.
  """
  @spec open_api_description(resource()) :: String.t() | nil
  def open_api_description(resource) do
    Extension.get_opt(resource, [:rest, :open_api], :description, nil) ||
      Ash.Resource.Info.description(resource)
  end

  @doc "Whether `resource` is an Ash resource using the `AshRest` extension."
  @spec rest_extension?(term()) :: boolean()
  def rest_extension?(resource) when is_map(resource), do: AshRest in Spark.extensions(resource)

  def rest_extension?(resource) when is_atom(resource) do
    Spark.Dsl.is?(resource, Ash.Resource) and AshRest in Spark.extensions(resource)
  end

  def rest_extension?(_), do: false

  @doc """
  The name of the resource's single primary key attribute.

  Raises `ArgumentError` when the resource has no primary key or a composite one.
  `AshRest.Resource.Verifiers.VerifyPrimaryKey` rejects those resources when they
  declare routes that address a single record.
  """
  @spec primary_key(resource()) :: atom()
  def primary_key(resource) do
    case Ash.Resource.Info.primary_key(resource) do
      [key] ->
        key

      keys ->
        raise ArgumentError,
              "AshRest needs exactly one primary key attribute, " <>
                "#{inspect(Extension.get_persisted(resource, :module))} has #{inspect(keys)}"
    end
  end
end
