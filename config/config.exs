# SPDX-FileCopyrightText: 2026 ash_rest contributors
#
# SPDX-License-Identifier: MIT

import Config

config :ash,
  default_string_length_count: :codepoints,
  validate_domain_resource_inclusion?: false,
  validate_domain_config_inclusion?: false,
  disable_async?: true

config :logger, level: :warning
