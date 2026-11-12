# SPDX-FileCopyrightText: 2026 ash_rest contributors
#
# SPDX-License-Identifier: MIT

defmodule AshRest.TestApp.Secret do
  @moduledoc false
  # Readable only by an actor with role :admin; used for 403 tests.
  use Ash.Resource,
    domain: AshRest.TestApp.Domain,
    data_layer: Ash.DataLayer.Ets,
    authorizers: [Ash.Policy.Authorizer],
    extensions: [AshRest]

  ets do
    private? true
  end

  rest do
    type "secret"
    base "/secrets"

    routes do
      index :read
      post :create
    end
  end

  attributes do
    uuid_primary_key :id
    attribute :value, :string, public?: true
  end

  actions do
    defaults [:read, create: :*]
  end

  policies do
    policy action_type(:read) do
      authorize_if actor_attribute_equals(:role, :admin)
    end

    policy action_type(:create) do
      forbid_if always()
    end
  end
end
