# SPDX-FileCopyrightText: 2026 ash_rest contributors
#
# SPDX-License-Identifier: MIT

defmodule AshRest.TestApp.Domain do
  @moduledoc false
  use Ash.Domain, extensions: [AshRest.Domain], validate_config_inclusion?: false

  resources do
    resource AshRest.TestApp.Author
    resource AshRest.TestApp.Post
    resource AshRest.TestApp.Comment
    resource AshRest.TestApp.Secret
    resource AshRest.TestApp.Note
  end
end
