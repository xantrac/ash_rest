# SPDX-FileCopyrightText: 2026 ash_rest contributors
#
# SPDX-License-Identifier: MIT

defmodule AshRest.TestApp.HandledRouter do
  @moduledoc false
  # The test domain behind a router-level error handler.
  use AshRest.Router,
    domains: [AshRest.TestApp.Domain],
    error_handler: AshRest.TestApp.ErrorHandler
end

defmodule AshRest.TestApp.VerboseRouter do
  @moduledoc false
  # The test domain with show_raised_errors? enabled.
  use AshRest.Router,
    domains: [AshRest.TestApp.Domain],
    show_raised_errors?: true
end
