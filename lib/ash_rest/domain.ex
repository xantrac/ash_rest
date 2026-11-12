# SPDX-FileCopyrightText: 2026 ash_rest contributors
#
# SPDX-License-Identifier: MIT

# Adapted from ash_json_api (MIT), https://github.com/ash-project/ash_json_api
defmodule AshRest.Domain do
  @rest %Spark.Dsl.Section{
    name: :rest,
    describe: "Domain-wide options for the REST API.",
    examples: [
      """
      rest do
        error_handler MyApp.RestErrorHandler
        show_raised_errors? false
      end
      """
    ],
    schema: [
      error_handler: [
        type: {:or, [{:behaviour, AshRpc.ErrorHandler}, :mfa]},
        doc: """
        Transforms errors before they are sent to the client. Either a module implementing
        `AshRpc.ErrorHandler` (called as `handle_error(error, context)`), or `{module, function, args}`
        applied as `apply(module, function, [error, context | args])`. Receives the ash_rpc error
        map and returns a map, or `nil` to drop the error.
        """
      ],
      show_raised_errors?: [
        type: :boolean,
        default: false,
        doc:
          "Whether to show the details of *raised* errors to clients. When false they are replaced by a generic error."
      ]
    ]
  }

  @moduledoc """
  The domain extension for AshRest, holding domain-wide options.

      use Ash.Domain, extensions: [AshRest.Domain]

      rest do
        error_handler MyApp.RestErrorHandler
      end

  Use `AshRest.Domain.Info` to read the configuration.
  """

  use Spark.Dsl.Extension, sections: [@rest]
end
