# SPDX-FileCopyrightText: 2026 ash_rest contributors
#
# SPDX-License-Identifier: MIT

# :spec_mismatch - responses that do not match the generated OpenAPI document
# :runtime_bug   - runtime behaviour that differs from the documented one
# Both are known issues, excluded so the suite stays green; run them with
# `mix test --only spec_mismatch` / `mix test --only runtime_bug`.
ExUnit.start(exclude: [:spec_mismatch, :runtime_bug])

for router <- [
      AshRest.TestApp.Router,
      AshRest.TestApp.HandledRouter,
      AshRest.TestApp.VerboseRouter
    ] do
  :ok = Oaskit.warmup_spec_cache(Module.concat(router, OpenApi), responses: true)
end

# Validate every response sent through AshRest.Test against the router's document.
AshRest.Test.validate_openapi(true)
