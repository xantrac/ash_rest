# SPDX-FileCopyrightText: 2026 ash_rest contributors
#
# SPDX-License-Identifier: MIT

defmodule AshRest.Resource.Verifiers.VerifyPrimaryKey do
  @moduledoc """
  Verifies that a resource with `get`, `patch`, `delete` or `related` routes has
  exactly one primary key attribute, which those routes address as `:id`.
  Composite primary keys are not supported.
  """
  use Spark.Dsl.Verifier

  alias AshRest.Resource.Verifiers.VerifyActions
  alias Spark.Dsl.Verifier

  @keyed_route_types [:get, :patch, :delete, :related]

  @impl true
  def verify(dsl) do
    keyed_routes =
      dsl
      |> Verifier.get_entities([:rest, :routes])
      |> Enum.filter(&(&1.type in @keyed_route_types))

    case {keyed_routes, Ash.Resource.Info.primary_key(dsl)} do
      {[], _} ->
        :ok

      {_, [_key]} ->
        :ok

      {[route | _] = routes, keys} ->
        module = Verifier.get_persisted(dsl, :module)

        problem =
          case keys do
            [] -> "#{inspect(module)} has no primary key"
            keys -> "#{inspect(module)} has a composite primary key #{inspect(keys)}"
          end

        {:error,
         Spark.Error.DslError.exception(
           module: module,
           path: [:rest, :routes],
           location: Spark.Dsl.Entity.anno(route),
           message: """
           #{problem}, but AshRest needs exactly one primary key attribute for routes that address a single record:

           #{Enum.map_join(routes, "\n", &("  * " <> VerifyActions.describe(&1)))}

           Composite primary keys are not supported.
           """
         )}
    end
  end
end
