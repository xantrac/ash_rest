# SPDX-FileCopyrightText: 2026 ash_rest contributors
#
# SPDX-License-Identifier: MIT

defmodule AshRest.TestApp.Comment do
  @moduledoc false
  use Ash.Resource,
    domain: AshRest.TestApp.Domain,
    data_layer: Ash.DataLayer.Ets,
    extensions: [AshRest]

  ets do
    private? true
  end

  rest do
    type "comment"
    base "/comments"
    includes [:post, :author]

    routes do
      get :read
      index :read
      post :create
      related :author, :read
    end
  end

  attributes do
    uuid_primary_key :id
    attribute :body, :string, public?: true, allow_nil?: false
    attribute :rating, :integer, public?: true
  end

  relationships do
    belongs_to :post, AshRest.TestApp.Post, public?: true, attribute_public?: true
    belongs_to :author, AshRest.TestApp.Author, public?: true, attribute_public?: true
  end

  actions do
    defaults [:read, :destroy, create: :*, update: :*]

    read :paginated do
      pagination offset?: true, keyset?: true, countable: true, required?: false
    end
  end
end
