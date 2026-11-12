# SPDX-FileCopyrightText: 2026 ash_rest contributors
#
# SPDX-License-Identifier: MIT

# Adapted from ash_json_api (MIT), https://github.com/ash-project/ash_json_api
defmodule AshRest.Resource.Verifiers.VerifyActions do
  @moduledoc """
  Verifies the actions and relationships referenced by every route.

    * the action exists, is `public?`, and its type matches the route kind
      (`get`/`index`/`related` -> `:read`, `post` -> `:create`, `patch` -> `:update`,
      `delete` -> `:destroy`, `route` -> any)
    * `read_action`, when set, is a public `:read` action
    * the relationship of a `related` route is a public relationship
  """
  use Spark.Dsl.Verifier

  alias Spark.Dsl.Verifier

  @allowed_action_types %{
    get: [:read],
    index: [:read],
    related: [:read],
    post: [:create],
    patch: [:update],
    delete: [:destroy]
  }

  @doc false
  @spec allowed_action_types() :: %{atom() => [atom()]}
  def allowed_action_types, do: @allowed_action_types

  @impl true
  def verify(dsl) do
    module = Verifier.get_persisted(dsl, :module)

    dsl
    |> Verifier.get_entities([:rest, :routes])
    |> Enum.flat_map(fn route ->
      [
        action_error(dsl, module, route),
        read_action_error(dsl, module, route),
        relationship_error(dsl, module, route)
      ]
      |> Enum.reject(&is_nil/1)
      |> Enum.map(&dsl_error(module, route, &1))
    end)
    |> case do
      [] -> :ok
      errors -> {:error, errors}
    end
  end

  defp action_error(dsl, module, route) do
    case Ash.Resource.Info.action(dsl, route.action) do
      nil ->
        "Route #{describe(route)} uses the action #{inspect(route.action)}, but #{inspect(module)} has no action with that name."

      action ->
        allowed = Map.get(@allowed_action_types, route.type)

        cond do
          allowed && action.type not in allowed ->
            "Route #{describe(route)} needs #{article(allowed)} action, but #{inspect(action.name)} is a #{inspect(action.type)} action."

          !Map.get(action, :public?, true) ->
            "Route #{describe(route)} uses the action #{inspect(action.name)}, which is not `public?`. Only public actions can be exposed."

          true ->
            nil
        end
    end
  end

  defp read_action_error(_dsl, _module, %{read_action: nil}), do: nil

  defp read_action_error(dsl, module, route) do
    case Ash.Resource.Info.action(dsl, route.read_action) do
      nil ->
        "Route #{describe(route)} sets `read_action: #{inspect(route.read_action)}`, but #{inspect(module)} has no action with that name."

      %{type: :read} = action ->
        if Map.get(action, :public?, true) do
          nil
        else
          "Route #{describe(route)} sets `read_action: #{inspect(action.name)}`, which is not `public?`. Only public actions can be exposed."
        end

      action ->
        "Route #{describe(route)} sets `read_action: #{inspect(action.name)}`, but it is a #{inspect(action.type)} action. It must be a :read action."
    end
  end

  defp relationship_error(dsl, module, %{type: :related, relationship: relationship} = route) do
    case Ash.Resource.Info.relationship(dsl, relationship) do
      nil ->
        "Route #{describe(route)} reads the relationship #{inspect(relationship)}, but #{inspect(module)} has no relationship with that name."

      %{public?: true} ->
        nil

      _ ->
        "Route #{describe(route)} reads the relationship #{inspect(relationship)}, which is not `public?`. Only public relationships can be exposed."
    end
  end

  defp relationship_error(_dsl, _module, _route), do: nil

  defp dsl_error(module, route, message) do
    Spark.Error.DslError.exception(
      module: module,
      path: [:rest, :routes],
      location: Spark.Dsl.Entity.anno(route),
      message: message
    )
  end

  defp article([type]), do: "a #{inspect(type)}"

  @doc false
  @spec describe(AshRest.Resource.Route.t()) :: String.t()
  def describe(%{type: :related} = route) do
    "`related #{inspect(route.relationship)}, #{inspect(route.action)}` (#{method(route)} #{route.route})"
  end

  def describe(%{type: :route} = route) do
    "`route #{inspect(route.method)}, ..., #{inspect(route.action)}` (#{method(route)} #{route.route})"
  end

  def describe(route) do
    "`#{route.type} #{inspect(route.action)}` (#{method(route)} #{route.route})"
  end

  defp method(route), do: route.method |> to_string() |> String.upcase()
end
