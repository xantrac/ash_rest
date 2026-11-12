<!--
SPDX-FileCopyrightText: 2026 ash_rest contributors

SPDX-License-Identifier: MIT
-->

# AshRest

A flat, Stripe-style REST API for [Ash](https://hexdocs.pm/ash) resources, with an
OpenAPI 3.1 document generated from the same configuration.

```
GET    /posts/:id                 -> 200 {"id": "d02f...", "type": "post", "title": "Hello", "author_id": "19cc..."}
GET    /posts?page[limit]=2       -> 200 {"data": [...], "has_more": true, "next_cursor": "g2wA...", "prev_cursor": null}
POST   /posts {"title": "Hello"}  -> 201 {"id": "...", "type": "post", "title": "Hello", ...}
PATCH  /posts/:id                 -> 200 the updated record
DELETE /posts/:id                 -> 200 the deleted record
errors                            -> {"error": {"status": 400, "code": "required", "message": "...", "details": [...]}}
```

> #### Status {: .warning}
>
> AshRest is pre-1.0 and depends on [`ash_rpc`](https://github.com/ash-project/ash_rpc),
> which is not released on Hex yet (it is pulled in from GitHub at a pinned commit).
> Expect breaking changes until both reach 1.0.

## Why

[AshJsonApi](https://hexdocs.pm/ash_json_api) implements the JSON:API specification:
`attributes`/`relationships` envelopes, `application/vnd.api+json`, compound documents.
Many API consumers would rather have plain JSON objects: a record is an object,
foreign keys are attributes, a list is `{"data": [...]}`, and errors are one predictable
envelope.

AshRest provides that flat format without re-implementing Ash's semantics. It is a thin HTTP
layer on top of `ash_rpc`, Ash's transport-agnostic RPC runtime. `ash_rpc` already does the hard
parts: casting input, rendering output by type (embedded resources, unions, typed maps,
calculations, aggregates), validating filters and sorts, pagination, tenancy and error
normalization. AshRest maps HTTP onto it: method and path pick the action, the query string
becomes `filter`/`sort`/`page`/`include`, the JSON body becomes the action input, and the
result becomes a status code and a flat JSON response.

## Installation

AshRest is not on Hex yet. Add it from GitHub. `ash_rpc` comes along as a git dependency of
AshRest, so you don't need to list it yourself. If you do depend on `ash_rpc` directly, use the
same commit as AshRest or `override: true`.

```elixir
def deps do
  [
    {:ash_rest, github: "xantrac/ash_rest"},
    # optional: OpenAPI document, /openapi.json, /docs and response validation in tests
    {:oaskit, "~> 0.18"}
  ]
end
```

Add `:ash_rest` to `import_deps` in `.formatter.exs` so the DSL formats without parentheses.

## Example

A resource declares its routes in a `rest` block:

```elixir
defmodule MyApp.Blog.Post do
  use Ash.Resource,
    domain: MyApp.Blog,
    data_layer: AshPostgres.DataLayer,
    extensions: [AshRest]

  rest do
    type "post"
    base "/posts"
    includes [:author]
    field_names inserted_at: "created_at"

    routes do
      get :read
      index :read
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

    attribute :status, :atom,
      public?: true,
      constraints: [one_of: [:draft, :published]],
      default: :draft

    create_timestamp :inserted_at, public?: true
  end

  relationships do
    belongs_to :author, MyApp.Blog.Author, public?: true, attribute_public?: true
  end

  actions do
    defaults [:destroy, create: [:title, :body, :author_id], update: [:title, :body]]

    read :read do
      primary? true
      pagination keyset?: true, countable: true, required?: false
    end

    update :publish do
      accept []
      change set_attribute(:status, :published)
    end
  end
end
```

A router serves every `AshRest` resource of the domains you give it:

```elixir
defmodule MyAppWeb.RestRouter do
  use AshRest.Router,
    domains: [MyApp.Blog],
    otp_app: :my_app,
    open_api_info: [title: "My App API", version: "1.0.0"]
end
```

The router is a plain `Plug`. Mount it in Phoenix with `forward`, behind whatever pipeline
authenticates your users. AshRest reads the actor and tenant with `Ash.PlugHelpers`, so plugs
that call `Ash.PlugHelpers.set_actor/2` (for example AshAuthentication's
`load_from_bearer` + `set_actor`) just work:

```elixir
# lib/my_app_web/router.ex
pipeline :api do
  plug :accepts, ["json"]
  plug :load_from_bearer
  plug :set_actor, :user
end

scope "/api" do
  pipe_through :api
  forward "/", MyAppWeb.RestRouter
end
```

## Wire format

Every example below is a real response from the resource above.

### Records

A record is a bare JSON object with a `"type"` key. Foreign keys are ordinary attributes.
Renamed fields (`field_names`) use their wire name everywhere: input, output, filter and sort.

`POST /api/posts` with `{"title": "Hello", "body": "First post", "author_id": "19ccd54d-..."}`
responds `201`:

```json
{
  "author_id": "19ccd54d-ddf5-44bc-adc8-15ea2085d4c4",
  "body": "First post",
  "created_at": "2026-11-12T03:21:13.517011Z",
  "id": "d02f6d4f-2d18-4f05-9298-20ccd5889721",
  "status": "draft",
  "title": "Hello",
  "type": "post"
}
```

Relationships appear only when requested with `include`, nested inline.
`GET /api/posts/d02f6d4f-...?include=author`:

```json
{
  "author": {
    "id": "19ccd54d-ddf5-44bc-adc8-15ea2085d4c4",
    "name": "Ada",
    "type": "author"
  },
  "author_id": "19ccd54d-ddf5-44bc-adc8-15ea2085d4c4",
  "body": "First post",
  "created_at": "2026-11-12T03:21:13.517011Z",
  "id": "d02f6d4f-2d18-4f05-9298-20ccd5889721",
  "status": "draft",
  "title": "Hello",
  "type": "post"
}
```

`PATCH /api/posts/:id` responds `200` with the updated record, `DELETE /api/posts/:id`
responds `200` with the deleted record, and `POST /api/posts/:id/publish` (a `route` to an
update action) responds `200` with the updated record.

### Lists

A list is wrapped in `data`. Without pagination that is the only key.
`GET /api/posts?filter[title][in][]=Hello&filter[title][in][]=Second&sort=-created_at`:

```json
{
  "data": [
    {
      "author_id": "19ccd54d-ddf5-44bc-adc8-15ea2085d4c4",
      "body": null,
      "created_at": "2026-11-12T03:21:13.519781Z",
      "id": "faab9208-1ac8-45be-acf7-cb3b46f9c336",
      "status": "draft",
      "title": "Second",
      "type": "post"
    },
    {
      "author_id": "19ccd54d-ddf5-44bc-adc8-15ea2085d4c4",
      "body": "First post",
      "created_at": "2026-11-12T03:21:13.517011Z",
      "id": "d02f6d4f-2d18-4f05-9298-20ccd5889721",
      "status": "draft",
      "title": "Hello",
      "type": "post"
    }
  ]
}
```

A paginated request adds `has_more`, `count` when `page[count]=true`, and cursors (keyset
pagination) or `limit`/`offset` (offset pagination).
`GET /api/posts?page[limit]=2&page[count]=true&sort=title`:

```json
{
  "count": 3,
  "data": [
    {
      "author_id": "19ccd54d-ddf5-44bc-adc8-15ea2085d4c4",
      "body": "First post",
      "created_at": "2026-11-12T03:21:13.517011Z",
      "id": "d02f6d4f-2d18-4f05-9298-20ccd5889721",
      "status": "draft",
      "title": "Hello",
      "type": "post"
    },
    {
      "author_id": "19ccd54d-ddf5-44bc-adc8-15ea2085d4c4",
      "body": null,
      "created_at": "2026-11-12T03:21:13.519781Z",
      "id": "faab9208-1ac8-45be-acf7-cb3b46f9c336",
      "status": "draft",
      "title": "Second",
      "type": "post"
    }
  ],
  "has_more": true,
  "next_cursor": "g2wAAAACbQAAAAZTZWNvbmRtAAAAJGZhYWI5MjA4LTFhYzgtNDViZS1hY2Y3LWNiM2I0NmY5YzMzNmo=",
  "prev_cursor": null
}
```

Pass `next_cursor` as `page[after]` for the next page, and `prev_cursor` as `page[before]`
to go back. Offset pages look like `{"data": [...], "has_more": true, "limit": 2, "offset": 0}`.
See [Filtering, sorting and pagination](documentation/topics/filtering-sorting-pagination.md).

### Errors

Every error uses one envelope. `status` is repeated in the body, `code` is machine-readable,
and `details` has one entry per underlying error, with the dotted path of the input it is about.
`POST /api/posts` with `{"body": "no title"}` responds `400`:

```json
{
  "error": {
    "code": "required",
    "details": [
      {
        "code": "required",
        "field": "title",
        "message": "attribute title is required"
      }
    ],
    "message": "attribute title is required",
    "status": 400
  }
}
```

A missing record is `404`:

```json
{"error": {"code": "not_found", "message": "record not found", "status": 404}}
```

See [Errors](documentation/topics/errors.md) for the status mapping and error handlers.

## OpenAPI

With `oaskit` installed, every router gets an OpenAPI 3.1 document generated from its routes
and the resources' types:

- `GET /openapi.json` serves the document (router option `open_api: "/openapi.json" | false`).
- `GET /docs` serves a Redoc page for it (router option `docs: "/docs" | false`).
- `use AshRest.Router` defines `MyAppWeb.RestRouter.OpenApi`, an `Oaskit` spec module, so you
  can write the document to a file:

  ```sh
  mix openapi.dump MyAppWeb.RestRouter.OpenApi --pretty -o priv/openapi.json
  ```

Each route is one operation whose `operationId` is the route name (`"post.get"`,
`"post.index"`, ...). Records, list wrappers, embedded resources, unions, filters and the error
envelope are components under `#/components/schemas`.

## Testing

`AshRest.Test` sends requests through a router with `Plug.Test` and asserts on the flat format.
With `oaskit`, it can also check every response against the generated document:

```elixir
# test/test_helper.exs
ExUnit.start()
AshRest.Test.validate_openapi(true)
```

```elixir
import AshRest.Test

test "creating a post" do
  MyAppWeb.RestRouter
  |> post("/posts", %{title: "Hello"}, actor: user)
  |> assert_record(%{"type" => "post", "title" => "Hello"})

  MyAppWeb.RestRouter
  |> post("/posts", %{}, status: 400, actor: user)
  |> assert_error_detail("title", "required")
end
```

## Documentation

- [Getting started](documentation/topics/getting-started.md)
- [Routes](documentation/topics/routes.md)
- [Filtering, sorting and pagination](documentation/topics/filtering-sorting-pagination.md)
- [Errors](documentation/topics/errors.md)
- [Resource DSL reference](documentation/dsls/DSL-AshRest.md)
- [Domain DSL reference](documentation/dsls/DSL-AshRest.Domain.md)

## License

MIT. Parts of the DSL are adapted from [AshJsonApi](https://github.com/ash-project/ash_json_api)
(MIT).
