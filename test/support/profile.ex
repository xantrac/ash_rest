# SPDX-FileCopyrightText: 2026 ash_rest contributors
#
# SPDX-License-Identifier: MIT

defmodule AshRest.TestApp.Profile do
  @moduledoc false
  # Embedded resource on Author.
  use Ash.Resource, data_layer: :embedded

  attributes do
    attribute :bio, :string, public?: true
    attribute :website, :string, public?: true
  end
end
