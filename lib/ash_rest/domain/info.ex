# SPDX-FileCopyrightText: 2026 ash_rest contributors
#
# SPDX-License-Identifier: MIT

defmodule AshRest.Domain.Info do
  @moduledoc """
  Introspection helpers for domains using the `AshRest.Domain` extension.

  `Spark.InfoGenerator` defines `rest_error_handler/1` (`{:ok, value} | :error`),
  `rest_error_handler!/1` and `rest_show_raised_errors?/1`. The helpers below return
  the value directly, with defaults applied.
  """
  use Spark.InfoGenerator, extension: AshRest.Domain, sections: [:rest]

  alias Spark.Dsl.Extension

  @doc """
  The configured error handler: a module implementing `AshRpc.ErrorHandler`,
  a `{module, function, args}` tuple, or `nil` when not configured.
  """
  @spec error_handler(Ash.Domain.t() | Spark.Dsl.t()) :: module() | mfa() | nil
  def error_handler(domain), do: Extension.get_opt(domain, [:rest], :error_handler, nil)

  @doc "Whether the details of raised errors are shown to clients. Defaults to `false`."
  @spec show_raised_errors?(Ash.Domain.t() | Spark.Dsl.t()) :: boolean()
  def show_raised_errors?(domain),
    do: Extension.get_opt(domain, [:rest], :show_raised_errors?, false)
end
