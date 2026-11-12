# SPDX-FileCopyrightText: 2026 ash_rest contributors
#
# SPDX-License-Identifier: MIT

# Adapted from ash_json_api (MIT), https://github.com/ash-project/ash_json_api
defmodule AshRest.Resource.Verifiers.VerifyNoOverlappingRoutes do
  @moduledoc """
  Verifies that no two routes of a resource match the same requests and that route
  names are unique.

  Two routes overlap when they have the same method and the same path, where any two
  `:param` segments are considered equal (`/posts/:id` overlaps `/posts/:slug`).
  """
  use Spark.Dsl.Verifier

  alias AshRest.Resource.Verifiers.VerifyActions
  alias Spark.Dsl.Verifier

  @impl true
  def verify(dsl) do
    module = Verifier.get_persisted(dsl, :module)
    routes = Verifier.get_entities(dsl, [:rest, :routes])

    overlap_errors =
      duplicates(routes, &{&1.method, path_shape(&1.route)}, fn earlier, route ->
        "Route #{VerifyActions.describe(route)} overlaps route #{VerifyActions.describe(earlier)}. " <>
          "Path parameters match any value, so both routes match the same requests."
      end)

    name_errors =
      duplicates(routes, & &1.name, fn earlier, route ->
        "Routes #{VerifyActions.describe(route)} and #{VerifyActions.describe(earlier)} both have the name #{inspect(route.name)}. " <>
          "Route names must be unique per resource: set `name` on one of them, e.g. `name: #{inspect(route.name <> "_" <> to_string(route.action))}`."
      end)

    (overlap_errors ++ name_errors)
    |> Enum.map(fn {route, message} ->
      Spark.Error.DslError.exception(
        module: module,
        path: [:rest, :routes],
        location: Spark.Dsl.Entity.anno(route),
        message: message
      )
    end)
    |> case do
      [] -> :ok
      errors -> {:error, errors}
    end
  end

  @doc false
  # The path with every `:param` segment replaced by `:`.
  @spec path_shape(String.t()) :: [String.t()]
  def path_shape(path) do
    path
    |> String.split("/", trim: true)
    |> Enum.map(fn
      ":" <> _ -> ":"
      segment -> segment
    end)
  end

  # Returns `{route, message}` for every route whose key was already used by an
  # earlier route, in declaration order.
  defp duplicates(routes, key_fun, message_fun) do
    {errors, _seen} =
      Enum.reduce(routes, {[], %{}}, fn route, {errors, seen} ->
        key = key_fun.(route)

        case Map.fetch(seen, key) do
          {:ok, earlier} -> {[{route, message_fun.(earlier, route)} | errors], seen}
          :error -> {errors, Map.put(seen, key, route)}
        end
      end)

    Enum.reverse(errors)
  end
end
