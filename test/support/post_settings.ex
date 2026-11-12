# SPDX-FileCopyrightText: 2026 ash_rest contributors
#
# SPDX-License-Identifier: MIT

defmodule AshRest.TestApp.PostSettings do
  @moduledoc false
  use Ash.Resource, data_layer: :embedded

  attributes do
    attribute :featured, :boolean, public?: true, default: false
    attribute :color, :string, public?: true
  end
end
