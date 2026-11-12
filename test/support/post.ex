# SPDX-FileCopyrightText: 2026 ash_rest contributors
#
# SPDX-License-Identifier: MIT

defmodule AshRest.TestApp.Post do
  @moduledoc false
  use Ash.Resource,
    domain: AshRest.TestApp.Domain,
    data_layer: Ash.DataLayer.Ets,
    extensions: [AshRest]

  ets do
    private? true
  end

  resource do
    description "A blog post."
  end

  rest do
    type "post"
    base "/posts"
    includes author: [], comments: [:author]
    field_names inserted_at: "created_at"

    routes do
      get :read
      index :read
      index :keyset, route: "/keyset", name: "post.keyset"
      index :offset, route: "/offset", name: "post.offset"
      post :create, request_body_description: "The post to create."
      patch :update
      delete :destroy
      related :comments, :read

      route :post, "/:id/publish", :publish do
        summary "Publish a post"

        description """
        Marks the post as published and stamps `published_by`.
        Publishing an already published post is a no-op.
        """

        response_description "The published post, with `meta.published_by`."
        parameter_descriptions id: "The post's UUID"
      end

      route :get, "/word_count", :word_count, query_params: [:text]
      route :post, "/stats", :stats, wrap_in_result?: true
      route :post, "/ping", :ping
    end
  end

  attributes do
    uuid_primary_key :id

    attribute :title, :string,
      public?: true,
      allow_nil?: false,
      description: "The headline of the post."

    attribute :body, :string, public?: true

    attribute :status, :atom,
      public?: true,
      constraints: [one_of: [:draft, :published]],
      default: :draft

    attribute :score, :integer, public?: true, default: 0
    attribute :published?, :boolean, public?: true, default: false
    attribute :settings, AshRest.TestApp.PostSettings, public?: true

    attribute :content, :union,
      public?: true,
      constraints: [
        types: [
          note: [type: :string],
          link: [
            type: :map,
            constraints: [fields: [url: [type: :string, allow_nil?: false]]]
          ]
        ]
      ]

    attribute :internal_notes, :string
    create_timestamp :inserted_at, public?: true
  end

  relationships do
    belongs_to :author, AshRest.TestApp.Author, public?: true, attribute_public?: true
    has_many :comments, AshRest.TestApp.Comment, public?: true
  end

  calculations do
    calculate :title_length, :integer, expr(string_length(title)), public?: true
  end

  aggregates do
    count :comment_count, :comments, public?: true
  end

  actions do
    defaults [:read, :destroy, create: :*, update: :*]

    read :keyset do
      pagination keyset?: true, countable: true, default_limit: 2, required?: false
    end

    read :offset do
      pagination offset?: true, countable: true, default_limit: 2, required?: false
    end

    update :publish do
      accept []
      require_atomic? false
      metadata :published_by, :string, allow_nil?: true
      change set_attribute(:status, :published)
      change set_attribute(:published?, true)

      change after_action(fn _changeset, record, _context ->
               {:ok, Ash.Resource.put_metadata(record, :published_by, "ash_rest")}
             end)
    end

    action :word_count, :integer do
      description "Counts the words in a text."
      argument :text, :string, allow_nil?: false, description: "The text to count words in."
      run fn input, _ -> {:ok, input.arguments.text |> String.split() |> length()} end
    end

    action :stats, :map do
      constraints fields: [total: [type: :integer, allow_nil?: false]]
      run fn _input, _ -> {:ok, %{total: 42}} end
    end

    action :ping do
      run fn _input, _ -> :ok end
    end
  end
end
