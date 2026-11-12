# SPDX-FileCopyrightText: 2026 ash_rest contributors
#
# SPDX-License-Identifier: MIT

# A tiny demo API for trying ash_rest by hand.
#
#     mix run dev/server.exs
#     curl -s localhost:4001/posts | jq
#     open http://localhost:4001/docs

defmodule Demo.Author do
  use Ash.Resource, domain: Demo.Blog, data_layer: Ash.DataLayer.Ets, extensions: [AshRest]

  rest do
    type "author"
    base "/authors"
    includes [:posts]

    routes do
      get :read
      index :read
      post :create
      related :posts, :read
    end
  end

  attributes do
    uuid_primary_key :id
    attribute :name, :string, public?: true, allow_nil?: false
  end

  relationships do
    has_many :posts, Demo.Post, public?: true
  end

  actions do
    defaults [:read, :destroy, create: :*, update: :*]
  end
end

defmodule Demo.Post do
  use Ash.Resource, domain: Demo.Blog, data_layer: Ash.DataLayer.Ets, extensions: [AshRest]

  rest do
    type "post"
    base "/posts"
    includes [:author]

    routes do
      get :read
      index :list
      post :create
      patch :update
      delete :destroy
      route :post, "/:id/publish", :publish
    end
  end

  attributes do
    uuid_primary_key :id
    attribute :title, :string, public?: true, allow_nil?: false
    attribute :body, :string, public?: true
    attribute :published, :boolean, public?: true, default: false
    create_timestamp :inserted_at, public?: true
  end

  relationships do
    belongs_to :author, Demo.Author, public?: true, attribute_public?: true
  end

  actions do
    defaults [:read, :destroy, create: :*, update: :*]

    read :list do
      pagination keyset?: true,
                 offset?: true,
                 countable: true,
                 default_limit: 20,
                 required?: false
    end

    update :publish do
      accept []
      change set_attribute(:published, true)
    end
  end
end

defmodule Demo.Blog do
  use Ash.Domain, validate_config_inclusion?: false

  resources do
    resource Demo.Author
    resource Demo.Post
  end
end

defmodule Demo.Router do
  use AshRest.Router,
    domains: [Demo.Blog],
    open_api_info: [title: "ash_rest demo", version: "0.1.0"]
end

ada = Ash.create!(Demo.Author, %{name: "Ada"})

for title <- ["Hello", "Flat APIs", "Keyset cursors"] do
  Ash.create!(Demo.Post, %{title: title, author_id: ada.id})
end

port = String.to_integer(System.get_env("PORT", "4001"))
{:ok, _} = Bandit.start_link(plug: Demo.Router, port: port)
IO.puts("ash_rest demo on http://localhost:#{port}  (docs: /docs, spec: /openapi.json)")

# Bandit is linked to this process; keep it alive.
Process.sleep(:infinity)
