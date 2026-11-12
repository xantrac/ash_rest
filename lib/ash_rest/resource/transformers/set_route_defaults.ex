# SPDX-FileCopyrightText: 2026 ash_rest contributors
#
# SPDX-License-Identifier: MIT

# Adapted from ash_json_api (MIT), https://github.com/ash-project/ash_json_api
defmodule AshRest.Resource.Transformers.SetRouteDefaults do
  @moduledoc """
  Completes the `rest` configuration of a resource.

    * validates and normalises `base` (must start with `/`, no trailing slash)
    * sets `type` to its default when it is not configured
    * for every route: sets `resource`, `action_type` (from the resource action),
      the default path of `related` routes, the default `name`, and prepends
      `base` to the route path
  """
  use Spark.Dsl.Transformer

  alias Spark.Dsl.Transformer

  @routes_path [:rest, :routes]

  @fallback_action_types %{
    get: :read,
    index: :read,
    related: :read,
    post: :create,
    patch: :update,
    delete: :destroy
  }

  # Default actions (`defaults [:read, ...]`) are built by these transformers.
  @impl true
  def after?(Ash.Resource.Transformers.SetPrimaryActions), do: true
  def after?(Ash.Resource.Transformers.DefaultAccept), do: true
  def after?(Ash.Resource.Transformers.CachePrimaryKey), do: true
  def after?(_), do: false

  @impl true
  def transform(dsl) do
    case Transformer.get_option(dsl, [:rest], :base) do
      nil ->
        # No `rest` section declared: nothing to complete.
        {:ok, dsl}

      base ->
        module = Transformer.get_persisted(dsl, :module)

        with {:ok, base} <- normalize_base(dsl, module, base) do
          type = Transformer.get_option(dsl, [:rest], :type) || default_type(module)

          dsl =
            dsl
            |> Transformer.set_option([:rest], :base, base)
            |> Transformer.set_option([:rest], :type, type)

          dsl =
            dsl
            |> Transformer.get_entities(@routes_path)
            |> Enum.reduce(dsl, fn route, dsl ->
              new_route = set_defaults(route, dsl, module, base, type)
              Transformer.replace_entity(dsl, @routes_path, new_route, &(&1 == route))
            end)

          {:ok, dsl}
        end
    end
  end

  @doc false
  @spec default_type(module()) :: String.t()
  def default_type(module) do
    module
    |> Module.split()
    |> List.last()
    |> Macro.underscore()
  end

  @doc false
  # Joins a base and a relative path, collapsing repeated slashes and dropping a
  # trailing slash (except for the root path).
  @spec join_path(String.t(), String.t() | nil) :: String.t()
  def join_path(base, path), do: normalize_path(base <> "/" <> (path || ""))

  @doc false
  @spec normalize_path(String.t()) :: String.t()
  def normalize_path(path) do
    "/" <> (path |> String.split("/", trim: true) |> Enum.join("/"))
  end

  defp normalize_base(_dsl, _module, "/" <> _ = base), do: {:ok, normalize_path(base)}

  defp normalize_base(dsl, module, base) do
    {:error,
     Spark.Error.DslError.exception(
       module: module,
       path: [:rest, :base],
       location: Transformer.get_opt_anno(dsl, [:rest], :base),
       message: "`base` must start with \"/\", got: #{inspect(base)}"
     )}
  end

  defp set_defaults(route, dsl, module, base, type) do
    action = Ash.Resource.Info.action(dsl, route.action)

    %{
      route
      | resource: module,
        route: join_path(base, route.route || default_route(route)),
        action_type: action_type(action, route),
        name: route.name || default_name(route, type)
    }
  end

  defp action_type(%{type: action_type}, _route), do: action_type

  # The action does not exist; `AshRest.Resource.Verifiers.VerifyActions` reports it.
  defp action_type(nil, route), do: Map.get(@fallback_action_types, route.type)

  defp default_route(%{type: :related, relationship: relationship}), do: "/:id/#{relationship}"
  defp default_route(_route), do: "/"

  defp default_name(%{type: :related, relationship: relationship}, type),
    do: "#{type}.related.#{relationship}"

  defp default_name(%{type: :route, action: action}, type), do: "#{type}.#{action}"
  defp default_name(%{type: route_type}, type), do: "#{type}.#{route_type}"
end
