# SPDX-FileCopyrightText: 2026 ash_rest contributors
#
# SPDX-License-Identifier: MIT

defmodule AshRest.TestApp.ErrorHandler do
  @moduledoc false
  # Used by AshRest.TestApp.HandledRouter: rewrites `required` messages and
  # drops `invalid_attribute` errors.
  @behaviour AshRpc.ErrorHandler

  @impl true
  def handle_error(%{type: "invalid_attribute"}, _context), do: nil

  def handle_error(%{type: "required"} = error, _context),
    do: %{error | message: "please provide %{field}", vars: Map.put(error.vars, :field, "it")}

  def handle_error(error, _context), do: error
end
