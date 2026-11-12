# SPDX-FileCopyrightText: 2026 ash_rest contributors
#
# SPDX-License-Identifier: MIT

# Adapted from ash_json_api (MIT), https://github.com/ash-project/ash_json_api
defmodule AshRest.Resource.Verifiers.VerifyIncludes do
  @moduledoc """
  Verifies that every key of the `includes` tree is a public relationship of the
  corresponding resource, following relationship destinations for nested keys.
  """
  use Spark.Dsl.Verifier

  alias Spark.Dsl.Verifier

  @impl true
  def verify(dsl) do
    module = Verifier.get_persisted(dsl, :module)
    location = Spark.Dsl.Transformer.get_opt_anno(dsl, [:rest], :includes)

    dsl
    |> Verifier.get_option([:rest], :includes, [])
    |> errors(dsl, module, [])
    |> Enum.map(fn {trail, message} ->
      Spark.Error.DslError.exception(
        module: module,
        path: [:rest, :includes | trail],
        location: location,
        message: message
      )
    end)
    |> case do
      [] -> :ok
      errors -> {:error, errors}
    end
  end

  # `resource` is the DSL state for the root and a module for destinations.
  defp errors(includes, resource, module, trail) do
    Enum.flat_map(includes, fn {name, nested} ->
      trail = trail ++ [name]
      source = if is_map(resource), do: module, else: resource

      case Ash.Resource.Info.relationship(resource, name) do
        nil ->
          [
            {trail,
             "Cannot include #{format_trail(trail)}: #{inspect(source)} has no relationship #{inspect(name)}."}
          ]

        %{public?: true, destination: destination} ->
          errors(nested, destination, module, trail)

        _ ->
          [
            {trail,
             "Cannot include #{format_trail(trail)}: the relationship #{inspect(source)}.#{name} is not `public?`."}
          ]
      end
    end)
  end

  defp format_trail(trail), do: Enum.join(trail, ".")
end
