# SPDX-FileCopyrightText: 2026 ash_rest contributors
#
# SPDX-License-Identifier: MIT

# Adapted from ash_json_api (MIT), https://github.com/ash-project/ash_json_api
defmodule AshRest do
  @route_schema [
    route: [
      type: :string,
      doc:
        "The path of the route, relative to `base`. May contain `:param` segments, e.g. `\"/:id/archive\"`."
    ],
    action: [
      type: :atom,
      required: true,
      doc: "The resource action to call when this route is hit."
    ],
    name: [
      type: :string,
      doc:
        "The entrypoint name of the route. Must be unique per resource. Defaults to `\"<type>.<route kind>\"`, e.g. `\"post.get\"`."
    ],
    description: [
      type: :string,
      doc: "A description of the route for generated docs. Defaults to the action description."
    ],
    primary?: [
      type: :boolean,
      default: false,
      doc: "Whether this is the route to link to by default for this kind of route."
    ],
    query_params: [
      type: {:list, :atom},
      default: [],
      doc: "Action inputs (arguments or accepted attributes) to read from the query string."
    ],
    metadata: [
      type: {:fun, 3},
      doc:
        "A function `fn subject, result, request -> map end` returning extra top-level metadata.",
      snippet: "fn ${1:subject}, ${2:result}, ${3:request} -> $4 end"
    ],
    modify_conn: [
      type: {:fun, 4},
      doc:
        "A function `fn conn, subject, result, request -> conn end` to modify the conn before responding, e.g. to set headers.",
      snippet: "fn ${1:conn}, ${2:subject}, ${3:result}, ${4:request} -> $5 end"
    ],
    enable_filter?: [
      type: :boolean,
      default: true,
      doc: "Whether the `filter` query parameter is accepted. Only used by `index` and `related`."
    ],
    enable_sort?: [
      type: :boolean,
      default: true,
      doc: "Whether the `sort` query parameter is accepted. Only used by `index` and `related`."
    ]
  ]

  @read_action_schema [
    read_action: [
      type: :atom,
      doc:
        "The read action used to look the record up before running the action. Defaults to the primary read action."
    ]
  ]

  @get %Spark.Dsl.Entity{
    name: :get,
    args: [:action],
    describe: "A `GET <base>/:id` route that reads a single record by primary key.",
    examples: [
      "get :read",
      ~S{get :by_slug, route: "/by-slug/:slug", name: "post.by_slug"}
    ],
    schema: Spark.Options.Helpers.set_default!(@route_schema, :route, "/:id"),
    target: AshRest.Resource.Route,
    auto_set_fields: [method: :get, type: :get]
  }

  @index %Spark.Dsl.Entity{
    name: :index,
    args: [:action],
    describe: "A `GET <base>` route that lists records.",
    examples: ["index :read", "index :read, paginate?: false"],
    schema:
      @route_schema
      |> Spark.Options.Helpers.set_default!(:route, "/")
      |> Keyword.put(:paginate?,
        type: :boolean,
        default: true,
        doc: "Whether to paginate the results when the read action supports pagination."
      ),
    target: AshRest.Resource.Route,
    auto_set_fields: [method: :get, type: :index]
  }

  @post %Spark.Dsl.Entity{
    name: :post,
    args: [:action],
    describe: "A `POST <base>` route that creates a record.",
    examples: ["post :create"],
    schema: Spark.Options.Helpers.set_default!(@route_schema, :route, "/"),
    target: AshRest.Resource.Route,
    auto_set_fields: [method: :post, type: :post]
  }

  @patch %Spark.Dsl.Entity{
    name: :patch,
    args: [:action],
    describe: "A `PATCH <base>/:id` route that updates a record.",
    examples: ["patch :update", "patch :update, read_action: :read_for_update"],
    schema:
      @route_schema
      |> Spark.Options.Helpers.set_default!(:route, "/:id")
      |> Keyword.merge(@read_action_schema),
    target: AshRest.Resource.Route,
    auto_set_fields: [method: :patch, type: :patch]
  }

  @delete %Spark.Dsl.Entity{
    name: :delete,
    args: [:action],
    describe: "A `DELETE <base>/:id` route that destroys a record.",
    examples: ["delete :destroy"],
    schema:
      @route_schema
      |> Spark.Options.Helpers.set_default!(:route, "/:id")
      |> Keyword.merge(@read_action_schema),
    target: AshRest.Resource.Route,
    auto_set_fields: [method: :delete, type: :delete]
  }

  @related %Spark.Dsl.Entity{
    name: :related,
    args: [:relationship, :action],
    describe: """
    A `GET <base>/:id/<relationship>` route that reads the related records of a relationship.

    `action` is the read action on *this* resource used to fetch the source record.
    """,
    examples: ["related :comments, :read"],
    schema:
      @route_schema
      |> Spark.Options.Helpers.append_doc!(:route, " Defaults to `\"/:id/<relationship>\"`.")
      |> Keyword.put(:relationship,
        type: :atom,
        required: true,
        doc: "The public relationship to read."
      ),
    target: AshRest.Resource.Route,
    auto_set_fields: [method: :get, type: :related]
  }

  @route %Spark.Dsl.Entity{
    name: :route,
    args: [:method, :route, :action],
    describe: """
    A route with an explicit method and path, for generic actions or any other action.

    The path is relative to `base` and may contain `:param` segments.
    """,
    examples: [
      ~S{route :post, "/:id/publish", :publish},
      ~S{route :get, "/stats", :stats, wrap_in_result?: true}
    ],
    schema:
      @route_schema
      |> Spark.Options.Helpers.make_required!(:route)
      |> Keyword.put(:method,
        type: {:one_of, [:get, :post, :put, :patch, :delete]},
        required: true,
        doc: "The HTTP method: `:get`, `:post`, `:put`, `:patch` or `:delete`."
      )
      |> Keyword.put(:wrap_in_result?,
        type: :boolean,
        default: false,
        doc: "Whether to wrap the action result as `{\"result\": <result>}`."
      ),
    target: AshRest.Resource.Route,
    auto_set_fields: [type: :route]
  }

  @routes %Spark.Dsl.Section{
    name: :routes,
    describe: "The routes exposed for this resource. Paths are relative to `base`.",
    examples: [
      """
      routes do
        get :read
        index :read
        post :create
        patch :update
        delete :destroy
        related :comments, :read
        route :post, "/:id/publish", :publish
      end
      """
    ],
    entities: [@get, @index, @post, @patch, @delete, @related, @route]
  }

  @rest %Spark.Dsl.Section{
    name: :rest,
    describe: "Configure how the resource is exposed in the REST API.",
    examples: [
      """
      rest do
        type "post"
        base "/posts"
        includes [author: [:profile], comments: [:author]]
        field_names [inserted_at: "created_at"]

        routes do
          get :read
          index :read
          post :create
        end
      end
      """
    ],
    sections: [@routes],
    schema: [
      type: [
        type: :string,
        doc:
          "The type name of the resource. Defaults to the underscored last segment of the module name, e.g. `BlogPost` -> `\"blog_post\"`."
      ],
      base: [
        type: :string,
        required: true,
        doc:
          "The base path of every route on this resource, e.g. `\"/posts\"`. Must start with `/`."
      ],
      includes: [
        type: {:custom, __MODULE__, :validate_includes, []},
        default: [],
        doc:
          "The relationships that may be included, as a keyword tree, e.g. `[author: [:profile], comments: []]`. A flat list of atoms is also accepted."
      ],
      field_names: [
        type: {:list, {:tuple, [:atom, :string]}},
        default: [],
        doc:
          "Renames fields in input and output, e.g. `[inserted_at: \"created_at\"]`. Unlisted fields keep their name."
      ],
      argument_names: [
        type: {:list, {:tuple, [:atom, {:list, {:tuple, [:atom, :string]}}]}},
        default: [],
        doc:
          "Renames action arguments per action, e.g. `[publish: [force?: \"force\"]]`. Unlisted arguments keep their name."
      ],
      include_nil_values?: [
        type: :boolean,
        default: true,
        doc: "Whether fields with `nil` values are included in the response body."
      ]
    ]
  }

  @moduledoc """
  The resource extension for AshRest: a flat REST API for Ash resources, built on `ash_rpc`.

  Add it to a resource and declare a `rest` section:

      use Ash.Resource,
        domain: MyApp.Blog,
        extensions: [AshRest]

      rest do
        base "/posts"

        routes do
          get :read
          index :read
          post :create
          patch :update
          delete :destroy
        end
      end

  Use `AshRest.Resource.Info` to introspect the configuration, and `AshRest.Domain`
  for domain-wide options.
  """

  use Spark.Dsl.Extension,
    sections: [@rest],
    transformers: [AshRest.Resource.Transformers.SetRouteDefaults],
    verifiers: [
      AshRest.Resource.Verifiers.VerifyActions,
      AshRest.Resource.Verifiers.VerifyIncludes,
      AshRest.Resource.Verifiers.VerifyNoOverlappingRoutes,
      AshRest.Resource.Verifiers.VerifyPrimaryKey
    ]

  @doc false
  @spec validate_includes(term()) :: {:ok, keyword()} | {:error, String.t()}
  def validate_includes(value) do
    case normalize_includes(value) do
      {:ok, includes} ->
        {:ok, includes}

      {:error, bad} ->
        {:error,
         "expected `includes` to be a relationship name, a list of names or a keyword tree of names, got invalid entry: #{inspect(bad)}"}
    end
  end

  @doc false
  # Normalises an includes tree to a nested keyword list with `[]` leaves,
  # deep-merging repeated keys: `[:a, a: [:b]]` -> `[a: [b: []]]`.
  @spec normalize_includes(term()) :: {:ok, keyword()} | {:error, term()}
  def normalize_includes(nil), do: {:ok, []}
  def normalize_includes(value) when is_boolean(value), do: {:error, value}
  def normalize_includes(value) when is_atom(value), do: {:ok, [{value, []}]}

  def normalize_includes(values) when is_list(values) do
    Enum.reduce_while(values, {:ok, []}, fn value, {:ok, acc} ->
      case normalize_include(value) do
        {:ok, {key, nested}} -> {:cont, {:ok, merge_include(acc, key, nested)}}
        {:error, bad} -> {:halt, {:error, bad}}
      end
    end)
  end

  def normalize_includes(value), do: {:error, value}

  defp normalize_include(key) when is_atom(key) and not is_nil(key) and not is_boolean(key),
    do: {:ok, {key, []}}

  defp normalize_include({key, nested} = value)
       when is_atom(key) and not is_nil(key) and not is_boolean(key) do
    case normalize_includes(nested) do
      {:ok, nested} -> {:ok, {key, nested}}
      {:error, _} -> {:error, value}
    end
  end

  defp normalize_include(value), do: {:error, value}

  defp merge_include(acc, key, nested) do
    if Keyword.has_key?(acc, key) do
      Keyword.update!(acc, key, fn existing ->
        Enum.reduce(nested, existing, fn {k, v}, acc -> merge_include(acc, k, v) end)
      end)
    else
      acc ++ [{key, nested}]
    end
  end
end
