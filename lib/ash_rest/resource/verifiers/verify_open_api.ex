# SPDX-FileCopyrightText: 2026 ash_rest contributors
#
# SPDX-License-Identifier: MIT

defmodule AshRest.Resource.Verifiers.VerifyOpenApi do
  @moduledoc """
  Verifies the OpenAPI customization of a resource:

    * `open_api.schema_name` is a valid OpenAPI component name (`[A-Za-z0-9._-]+`)
    * every key of a route's `parameter_descriptions` is one of the route's path
      parameters or `query_params`
  """
  use Spark.Dsl.Verifier

  alias AshRest.Resource.Verifiers.VerifyActions
  alias Spark.Dsl.Verifier

  @component_name ~r/^[A-Za-z0-9._-]+$/

  @impl true
  def verify(dsl) do
    module = Verifier.get_persisted(dsl, :module)

    errors =
      schema_name_errors(dsl, module) ++
        Enum.flat_map(Verifier.get_entities(dsl, [:rest, :routes]), &parameter_errors(&1, module))

    case errors do
      [] -> :ok
      errors -> {:error, errors}
    end
  end

  defp schema_name_errors(dsl, module) do
    case Verifier.get_option(dsl, [:rest, :open_api], :schema_name) do
      nil ->
        []

      name ->
        if Regex.match?(@component_name, name) do
          []
        else
          [
            Spark.Error.DslError.exception(
              module: module,
              path: [:rest, :open_api, :schema_name],
              message:
                "`schema_name` #{inspect(name)} is not a valid OpenAPI component name: " <>
                  "use only letters, digits, `.`, `_` and `-`."
            )
          ]
        end
    end
  end

  defp parameter_errors(%{parameter_descriptions: []}, _module), do: []

  defp parameter_errors(route, module) do
    allowed = path_params(route.route) ++ Enum.map(route.query_params, &to_string/1)

    case Enum.reject(Keyword.keys(route.parameter_descriptions), &(to_string(&1) in allowed)) do
      [] ->
        []

      unknown ->
        [
          Spark.Error.DslError.exception(
            module: module,
            path: [:rest, :routes],
            location: Spark.Dsl.Entity.anno(route),
            message: """
            `parameter_descriptions` of #{VerifyActions.describe(route)} names unknown parameters: \
            #{Enum.map_join(unknown, ", ", &inspect/1)}.

            Describable parameters of this route: #{describe_allowed(allowed)}.
            """
          )
        ]
    end
  end

  defp path_params(path), do: for(":" <> name <- String.split(path, "/", trim: true), do: name)

  defp describe_allowed([]), do: "none"
  defp describe_allowed(names), do: Enum.map_join(names, ", ", &("`" <> &1 <> "`"))
end
