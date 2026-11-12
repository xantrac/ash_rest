# SPDX-FileCopyrightText: 2026 ash_rest contributors
#
# SPDX-License-Identifier: MIT

defmodule AshRest.TestApp.Router do
  @moduledoc false
  use AshRest.Router,
    domains: [AshRest.TestApp.Domain],
    open_api_info: [title: "AshRest test API", version: "1.0.0"]
end
