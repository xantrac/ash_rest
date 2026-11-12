# SPDX-FileCopyrightText: 2026 ash_rest contributors
#
# SPDX-License-Identifier: MIT

defmodule AshRest.TestApp.Author do
  @moduledoc false
  use Ash.Resource,
    domain: AshRest.TestApp.Domain,
    data_layer: Ash.DataLayer.Ets,
    extensions: [AshRest]

  ets do
    private? true
  end

  rest do
    type "author"
    base "/authors"
    includes [:posts]

    routes do
      get :read
      index :read
      post :create
      related :posts, :read

      related :posts, :read,
        route: "/:id/posts_unfiltered",
        name: "author.posts_unfiltered",
        enable_filter?: false,
        enable_sort?: false
    end
  end

  attributes do
    uuid_primary_key :id
    attribute :name, :string, public?: true, allow_nil?: false
    attribute :email, :string, public?: true
    attribute :profile, AshRest.TestApp.Profile, public?: true
  end

  relationships do
    has_many :posts, AshRest.TestApp.Post, public?: true
  end

  actions do
    defaults [:read, :destroy, create: :*, update: :*]
  end
end
