# SPDX-FileCopyrightText: 2026 ash_rest contributors
#
# SPDX-License-Identifier: MIT

defmodule AshRest.DslTest do
  use ExUnit.Case, async: true

  import Spark.Test

  alias AshRest.Resource.Info
  alias AshRest.Resource.Route

  defmodule ErrorHandler do
    @moduledoc false
    @behaviour AshRpc.ErrorHandler

    @impl true
    def handle_error(error, _context), do: error
  end

  defmodule Profile do
    @moduledoc false
    use Ash.Resource, domain: AshRest.DslTest.Domain, data_layer: Ash.DataLayer.Ets

    ets do
      private? true
    end

    attributes do
      uuid_primary_key :id
      attribute :bio, :string, public?: true
    end

    relationships do
      belongs_to :author, AshRest.DslTest.Author, public?: true
    end

    actions do
      defaults [:read]
    end
  end

  defmodule Author do
    @moduledoc false
    use Ash.Resource,
      domain: AshRest.DslTest.Domain,
      data_layer: Ash.DataLayer.Ets,
      extensions: [AshRest]

    ets do
      private? true
    end

    rest do
      base "/authors"

      routes do
        get :read
      end
    end

    attributes do
      uuid_primary_key :id
      attribute :name, :string, public?: true
    end

    relationships do
      has_one :profile, AshRest.DslTest.Profile, public?: true
    end

    actions do
      defaults [:read]
    end
  end

  defmodule Comment do
    @moduledoc false
    use Ash.Resource, domain: AshRest.DslTest.Domain, data_layer: Ash.DataLayer.Ets

    ets do
      private? true
    end

    attributes do
      uuid_primary_key :id
      attribute :body, :string, public?: true
    end

    relationships do
      belongs_to :post, AshRest.DslTest.BlogPost, public?: true
      belongs_to :author, AshRest.DslTest.Author, public?: true
    end

    actions do
      defaults [:read]
    end
  end

  defmodule BlogPost do
    @moduledoc false
    use Ash.Resource,
      domain: AshRest.DslTest.Domain,
      data_layer: Ash.DataLayer.Ets,
      extensions: [AshRest]

    ets do
      private? true
    end

    rest do
      base "/posts"
      includes [:comments, author: :profile, comments: [:author]]
      field_names inserted_at: "created_at", title: "headline"
      argument_names publish: [force?: "force"]

      routes do
        get :read

        index :read do
          paginate? false
          metadata fn _subject, _result, _request -> %{"total" => 0} end
        end

        post :create
        patch :update
        delete :destroy, read_action: :read

        related :comments, :read do
          enable_filter? false
        end

        route :post, "/:id/publish", :publish
        route :get, "/stats", :stats, wrap_in_result?: true
        get :by_slug, route: "/by-slug/:slug", name: "blog_post.by_slug"
      end
    end

    attributes do
      uuid_primary_key :id
      attribute :title, :string, public?: true
      attribute :slug, :string, public?: true
      create_timestamp :inserted_at, public?: true
    end

    relationships do
      belongs_to :author, AshRest.DslTest.Author, public?: true

      has_many :comments, AshRest.DslTest.Comment,
        destination_attribute: :post_id,
        public?: true
    end

    actions do
      defaults [:read, :destroy, create: :*, update: :*]

      read :by_slug do
        argument :slug, :string, allow_nil?: false
        filter expr(slug == ^arg(:slug))
      end

      update :publish do
        argument :force?, :boolean, default: false
      end

      action :stats, :map do
        run fn _input, _context -> {:ok, %{}} end
      end
    end
  end

  defmodule Thing do
    @moduledoc false
    use Ash.Resource,
      domain: AshRest.DslTest.Domain,
      data_layer: Ash.DataLayer.Ets,
      extensions: [AshRest]

    ets do
      private? true
    end

    rest do
      type "widget"
      base "/v1//things/"
      include_nil_values? false

      routes do
        index :read
        get :read, route: "/:id/"
        route :get, "//ping/", :ping
      end
    end

    attributes do
      uuid_primary_key :id
    end

    actions do
      defaults [:read]

      action :ping, :string do
        run fn _input, _context -> {:ok, "pong"} end
      end
    end
  end

  defmodule Root do
    @moduledoc false
    use Ash.Resource,
      domain: AshRest.DslTest.Domain,
      data_layer: Ash.DataLayer.Ets,
      extensions: [AshRest]

    ets do
      private? true
    end

    rest do
      base "/"

      routes do
        index :read
        route :get, "/health", :health
      end
    end

    attributes do
      uuid_primary_key :id
    end

    actions do
      defaults [:read]

      action :health, :string do
        run fn _input, _context -> {:ok, "ok"} end
      end
    end
  end

  defmodule Composite do
    @moduledoc false
    use Ash.Resource,
      domain: AshRest.DslTest.Domain,
      data_layer: Ash.DataLayer.Ets,
      extensions: [AshRest]

    ets do
      private? true
    end

    rest do
      base "/composites"

      routes do
        index :read
        post :create
      end
    end

    attributes do
      attribute :first, :string, primary_key?: true, allow_nil?: false, public?: true
      attribute :second, :string, primary_key?: true, allow_nil?: false, public?: true
    end

    actions do
      defaults [:read, create: :*]
    end
  end

  defmodule Plain do
    @moduledoc false
    use Ash.Resource, domain: AshRest.DslTest.Domain, data_layer: Ash.DataLayer.Ets

    ets do
      private? true
    end

    attributes do
      uuid_primary_key :id
    end

    actions do
      defaults [:read]
    end
  end

  defmodule Domain do
    @moduledoc false
    use Ash.Domain, extensions: [AshRest.Domain]

    rest do
      error_handler AshRest.DslTest.ErrorHandler
      show_raised_errors? true
    end

    resources do
      resource AshRest.DslTest.Profile
      resource AshRest.DslTest.Author
      resource AshRest.DslTest.Comment
      resource AshRest.DslTest.BlogPost
      resource AshRest.DslTest.Thing
      resource AshRest.DslTest.Root
      resource AshRest.DslTest.Composite
      resource AshRest.DslTest.Plain
    end
  end

  defmodule MfaDomain do
    @moduledoc false
    use Ash.Domain, extensions: [AshRest.Domain]

    rest do
      error_handler {AshRest.DslTest.ErrorHandler, :handle_error, []}
    end
  end

  defmodule BareDomain do
    @moduledoc false
    use Ash.Domain, extensions: [AshRest.Domain]
  end

  defp route!(resource, name) do
    Enum.find(Info.routes(resource), &(&1.name == name)) ||
      flunk("no route named #{inspect(name)} on #{inspect(resource)}")
  end

  describe "route defaults" do
    test "routes keep declaration order and get default names" do
      assert Enum.map(Info.routes(BlogPost), & &1.name) == [
               "blog_post.get",
               "blog_post.index",
               "blog_post.post",
               "blog_post.patch",
               "blog_post.delete",
               "blog_post.related.comments",
               "blog_post.publish",
               "blog_post.stats",
               "blog_post.by_slug"
             ]
    end

    test "get" do
      assert %Route{
               method: :get,
               type: :get,
               route: "/posts/:id",
               action: :read,
               action_type: :read,
               resource: BlogPost,
               relationship: nil,
               read_action: nil,
               primary?: false,
               query_params: [],
               enable_filter?: true,
               enable_sort?: true
             } = route!(BlogPost, "blog_post.get")
    end

    test "index, with options set in a do block" do
      route = route!(BlogPost, "blog_post.index")

      assert %Route{
               method: :get,
               type: :index,
               route: "/posts",
               action: :read,
               action_type: :read,
               paginate?: false
             } = route

      assert route.metadata.(nil, nil, nil) == %{"total" => 0}
    end

    test "post" do
      assert %Route{
               method: :post,
               type: :post,
               route: "/posts",
               action: :create,
               action_type: :create
             } = route!(BlogPost, "blog_post.post")
    end

    test "patch" do
      assert %Route{
               method: :patch,
               type: :patch,
               route: "/posts/:id",
               action: :update,
               action_type: :update
             } = route!(BlogPost, "blog_post.patch")
    end

    test "delete" do
      assert %Route{
               method: :delete,
               type: :delete,
               route: "/posts/:id",
               action: :destroy,
               action_type: :destroy,
               read_action: :read
             } = route!(BlogPost, "blog_post.delete")
    end

    test "related" do
      assert %Route{
               method: :get,
               type: :related,
               route: "/posts/:id/comments",
               relationship: :comments,
               action: :read,
               action_type: :read,
               enable_filter?: false,
               enable_sort?: true
             } = route!(BlogPost, "blog_post.related.comments")
    end

    test "route takes the action type of the action it calls" do
      assert %Route{
               method: :post,
               type: :route,
               route: "/posts/:id/publish",
               action: :publish,
               action_type: :update,
               wrap_in_result?: false
             } = route!(BlogPost, "blog_post.publish")

      assert %Route{
               method: :get,
               type: :route,
               route: "/posts/stats",
               action: :stats,
               action_type: :action,
               wrap_in_result?: true
             } = route!(BlogPost, "blog_post.stats")
    end

    test "a route override is relative to base and keeps an explicit name" do
      assert %Route{method: :get, type: :get, route: "/posts/by-slug/:slug", action: :by_slug} =
               route!(BlogPost, "blog_post.by_slug")
    end

    test "paths are normalised: repeated and trailing slashes are removed" do
      assert Info.base(Thing) == "/v1/things"

      assert Enum.map(Info.routes(Thing), &{&1.name, &1.route}) == [
               {"widget.index", "/v1/things"},
               {"widget.get", "/v1/things/:id"},
               {"widget.ping", "/v1/things/ping"}
             ]
    end

    test "a root base keeps the root path" do
      assert Info.base(Root) == "/"

      assert Enum.map(Info.routes(Root), &{&1.name, &1.route}) == [
               {"root.index", "/"},
               {"root.health", "/health"}
             ]
    end
  end

  describe "AshRest.Resource.Info" do
    test "type/1 defaults to the underscored module name" do
      assert Info.type(BlogPost) == "blog_post"
      assert Info.type(Author) == "author"
      assert Info.type(Thing) == "widget"
    end

    test "the default type is persisted for the generated functions" do
      assert Info.rest_type(BlogPost) == {:ok, "blog_post"}
      assert Info.rest_type!(Thing) == "widget"
    end

    test "base/1" do
      assert Info.base(BlogPost) == "/posts"
      assert Info.base(Plain) == nil
    end

    test "routes/1 matches the generated rest_routes/1" do
      assert Info.routes(BlogPost) == Info.rest_routes(BlogPost)
      assert Info.routes(Plain) == []
    end

    test "includes/1 is a normalised, merged keyword tree" do
      assert Info.includes(BlogPost) == [comments: [author: []], author: [profile: []]]
      assert Info.includes(Author) == []
    end

    test "field_names/1" do
      assert Info.field_names(BlogPost) == %{inserted_at: "created_at", title: "headline"}
      assert Info.field_names(Author) == %{}
    end

    test "argument_names/2" do
      assert Info.argument_names(BlogPost, :publish) == %{force?: "force"}
      assert Info.argument_names(BlogPost, :create) == %{}
    end

    test "include_nil_values?/1" do
      assert Info.include_nil_values?(BlogPost) == true
      assert Info.include_nil_values?(Thing) == false
    end

    test "rest_extension?/1" do
      assert Info.rest_extension?(BlogPost)
      refute Info.rest_extension?(Plain)
      refute Info.rest_extension?(String)
      refute Info.rest_extension?("not a module")
    end

    test "primary_key/1" do
      assert Info.primary_key(BlogPost) == :id

      assert_raise ArgumentError, ~r/exactly one primary key/, fn ->
        Info.primary_key(Composite)
      end
    end
  end

  describe "AshRest.Domain.Info" do
    test "configured options" do
      assert AshRest.Domain.Info.error_handler(Domain) == ErrorHandler
      assert AshRest.Domain.Info.show_raised_errors?(Domain) == true
      assert AshRest.Domain.Info.rest_error_handler(Domain) == {:ok, ErrorHandler}

      assert AshRest.Domain.Info.error_handler(MfaDomain) ==
               {ErrorHandler, :handle_error, []}
    end

    test "defaults" do
      assert AshRest.Domain.Info.error_handler(BareDomain) == nil
      assert AshRest.Domain.Info.show_raised_errors?(BareDomain) == false
      assert AshRest.Domain.Info.rest_error_handler(BareDomain) == :error
    end

    test "rejects an invalid error_handler" do
      assert_raise Spark.Error.DslError, ~r/error_handler/, fn ->
        defmodule Elixir.AshRest.DslTest.BadHandlerDomain do
          use Ash.Domain, extensions: [AshRest.Domain]

          rest do
            error_handler "not a handler"
          end
        end
      end
    end
  end

  describe "option validation" do
    test "base must start with a slash" do
      assert_raise Spark.Error.DslError, ~r/must start with "\/"/, fn ->
        defmodule Elixir.AshRest.DslTest.BadBase do
          use Ash.Resource, domain: nil, data_layer: Ash.DataLayer.Ets, extensions: [AshRest]

          rest do
            base "posts"
          end

          attributes do
            uuid_primary_key :id
          end
        end
      end
    end

    test "includes must be relationship names" do
      assert_raise Spark.Error.DslError, ~r/includes/, fn ->
        defmodule Elixir.AshRest.DslTest.BadIncludesShape do
          use Ash.Resource, domain: nil, data_layer: Ash.DataLayer.Ets, extensions: [AshRest]

          rest do
            base "/x"
            includes ["author"]
          end

          attributes do
            uuid_primary_key :id
          end
        end
      end
    end

    test "route methods are restricted" do
      assert_raise Spark.Error.DslError, ~r/method/, fn ->
        defmodule Elixir.AshRest.DslTest.BadMethod do
          use Ash.Resource, domain: nil, data_layer: Ash.DataLayer.Ets, extensions: [AshRest]

          rest do
            base "/x"

            routes do
              route :head, "/", :read
            end
          end

          attributes do
            uuid_primary_key :id
          end

          actions do
            defaults [:read]
          end
        end
      end
    end
  end

  describe "VerifyActions" do
    test "accepts a valid configuration" do
      refute_dsl_errors do
        defmodule Elixir.AshRest.DslTest.ValidActions do
          use Ash.Resource, domain: nil, data_layer: Ash.DataLayer.Ets, extensions: [AshRest]

          rest do
            base "/valid"

            routes do
              get :read
              patch :update, read_action: :read
              route :get, "/ping", :ping
            end
          end

          attributes do
            uuid_primary_key :id
          end

          actions do
            defaults [:read, update: :*]

            action :ping, :string do
              run fn _input, _context -> {:ok, "pong"} end
            end
          end
        end
      end
    end

    test "rejects an unknown action" do
      error =
        assert_dsl_error %Spark.Error.DslError{path: [:rest, :routes]} do
          defmodule Elixir.AshRest.DslTest.UnknownAction do
            use Ash.Resource, domain: nil, data_layer: Ash.DataLayer.Ets, extensions: [AshRest]

            rest do
              base "/x"

              routes do
                get :missing
              end
            end

            attributes do
              uuid_primary_key :id
            end

            actions do
              defaults [:read]
            end
          end
        end

      assert error.message =~ ":missing"
      assert error.message =~ "no action with that name"
    end

    test "rejects an action of the wrong type" do
      error =
        assert_dsl_error %Spark.Error.DslError{path: [:rest, :routes]} do
          defmodule Elixir.AshRest.DslTest.WrongActionType do
            use Ash.Resource, domain: nil, data_layer: Ash.DataLayer.Ets, extensions: [AshRest]

            rest do
              base "/x"

              routes do
                post :read
              end
            end

            attributes do
              uuid_primary_key :id
            end

            actions do
              defaults [:read]
            end
          end
        end

      assert error.message =~ "needs a :create action"
    end

    test "rejects a private action" do
      error =
        assert_dsl_error %Spark.Error.DslError{path: [:rest, :routes]} do
          defmodule Elixir.AshRest.DslTest.PrivateAction do
            use Ash.Resource, domain: nil, data_layer: Ash.DataLayer.Ets, extensions: [AshRest]

            rest do
              base "/x"

              routes do
                index :secret
              end
            end

            attributes do
              uuid_primary_key :id
            end

            actions do
              read :secret do
                public? false
              end
            end
          end
        end

      assert error.message =~ "not `public?`"
    end

    test "rejects a read_action that is not a read" do
      error =
        assert_dsl_error %Spark.Error.DslError{path: [:rest, :routes]} do
          defmodule Elixir.AshRest.DslTest.BadReadAction do
            use Ash.Resource, domain: nil, data_layer: Ash.DataLayer.Ets, extensions: [AshRest]

            rest do
              base "/x"

              routes do
                patch :update, read_action: :create
              end
            end

            attributes do
              uuid_primary_key :id
            end

            actions do
              defaults [:read, create: :*, update: :*]
            end
          end
        end

      assert error.message =~ "must be a :read action"
    end

    test "rejects a related route for an unknown relationship" do
      error =
        assert_dsl_error %Spark.Error.DslError{path: [:rest, :routes]} do
          defmodule Elixir.AshRest.DslTest.UnknownRelationship do
            use Ash.Resource, domain: nil, data_layer: Ash.DataLayer.Ets, extensions: [AshRest]

            rest do
              base "/x"

              routes do
                related :nope, :read
              end
            end

            attributes do
              uuid_primary_key :id
            end

            actions do
              defaults [:read]
            end
          end
        end

      assert error.message =~ "no relationship with that name"
    end
  end

  describe "VerifyIncludes" do
    test "rejects an unknown relationship" do
      error =
        assert_dsl_error %Spark.Error.DslError{path: [:rest, :includes, :nope]} do
          defmodule Elixir.AshRest.DslTest.UnknownInclude do
            use Ash.Resource, domain: nil, data_layer: Ash.DataLayer.Ets, extensions: [AshRest]

            rest do
              base "/x"
              includes [:nope]
            end

            attributes do
              uuid_primary_key :id
            end
          end
        end

      assert error.message =~ "no relationship :nope"
    end

    test "rejects an unknown nested relationship" do
      error =
        assert_dsl_error %Spark.Error.DslError{path: [:rest, :includes, :author, :nope]} do
          defmodule Elixir.AshRest.DslTest.UnknownNestedInclude do
            use Ash.Resource, domain: nil, data_layer: Ash.DataLayer.Ets, extensions: [AshRest]

            rest do
              base "/x"
              includes author: [:profile, :nope]
            end

            attributes do
              uuid_primary_key :id
            end

            relationships do
              belongs_to :author, AshRest.DslTest.Author, public?: true
            end
          end
        end

      assert error.message =~ "AshRest.DslTest.Author has no relationship :nope"
    end

    test "rejects a private relationship" do
      error =
        assert_dsl_error %Spark.Error.DslError{path: [:rest, :includes, :author]} do
          defmodule Elixir.AshRest.DslTest.PrivateInclude do
            use Ash.Resource, domain: nil, data_layer: Ash.DataLayer.Ets, extensions: [AshRest]

            rest do
              base "/x"
              includes [:author]
            end

            attributes do
              uuid_primary_key :id
            end

            relationships do
              belongs_to :author, AshRest.DslTest.Author
            end
          end
        end

      assert error.message =~ "is not `public?`"
    end
  end

  describe "VerifyNoOverlappingRoutes" do
    test "rejects two routes that differ only in path parameter names" do
      error =
        assert_dsl_error %Spark.Error.DslError{path: [:rest, :routes]} do
          defmodule Elixir.AshRest.DslTest.OverlappingRoutes do
            use Ash.Resource, domain: nil, data_layer: Ash.DataLayer.Ets, extensions: [AshRest]

            rest do
              base "/x"

              routes do
                get :read
                get :by_slug, route: "/:slug", name: "x.by_slug"
              end
            end

            attributes do
              uuid_primary_key :id
              attribute :slug, :string, public?: true
            end

            actions do
              defaults [:read]

              read :by_slug do
                argument :slug, :string
              end
            end
          end
        end

      assert error.message =~ "overlaps"
      assert error.message =~ "GET /x/:slug"
    end

    test "rejects duplicate route names" do
      error =
        assert_dsl_error %Spark.Error.DslError{path: [:rest, :routes]} do
          defmodule Elixir.AshRest.DslTest.DuplicateNames do
            use Ash.Resource, domain: nil, data_layer: Ash.DataLayer.Ets, extensions: [AshRest]

            rest do
              base "/x"

              routes do
                get :read
                get :by_slug, route: "/by-slug/:slug"
              end
            end

            attributes do
              uuid_primary_key :id
              attribute :slug, :string, public?: true
            end

            actions do
              defaults [:read]

              read :by_slug do
                argument :slug, :string
              end
            end
          end
        end

      assert error.message =~ ~s(both have the name "duplicate_names.get")
      assert error.message =~ "set `name`"
    end
  end

  describe "VerifyPrimaryKey" do
    test "rejects a composite primary key with routes that address one record" do
      error =
        assert_dsl_error %Spark.Error.DslError{path: [:rest, :routes]} do
          defmodule Elixir.AshRest.DslTest.CompositeWithGet do
            use Ash.Resource, domain: nil, data_layer: Ash.DataLayer.Ets, extensions: [AshRest]

            rest do
              base "/x"

              routes do
                index :read
                get :read
              end
            end

            attributes do
              attribute :first, :string, primary_key?: true, allow_nil?: false, public?: true
              attribute :second, :string, primary_key?: true, allow_nil?: false, public?: true
            end

            actions do
              defaults [:read]
            end
          end
        end

      assert error.message =~ "composite primary key [:first, :second]"
      assert error.message =~ "* `get :read` (GET /x/:id)"
    end

    test "accepts a composite primary key with collection routes only" do
      refute_dsl_errors do
        defmodule Elixir.AshRest.DslTest.CompositeCollectionOnly do
          use Ash.Resource, domain: nil, data_layer: Ash.DataLayer.Ets, extensions: [AshRest]

          rest do
            base "/x"

            routes do
              index :read
            end
          end

          attributes do
            attribute :first, :string, primary_key?: true, allow_nil?: false, public?: true
            attribute :second, :string, primary_key?: true, allow_nil?: false, public?: true
          end

          actions do
            defaults [:read]
          end
        end
      end
    end
  end
end
