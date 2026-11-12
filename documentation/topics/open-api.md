<!--
SPDX-FileCopyrightText: 2026 ash_rest contributors

SPDX-License-Identifier: MIT
-->

# OpenAPI

With [`oaskit`](https://hexdocs.pm/oaskit) installed, every `AshRest.Router` gets an OpenAPI 3.1
document generated from its routes and the types of its resources.

- `GET /openapi.json` serves the document (router option `open_api: "/openapi.json" | false`).
- `GET /docs` serves a Redoc page for it (router option `docs: "/docs" | false`).
- `use AshRest.Router` defines `<Router>.OpenApi`, an `Oaskit` spec module, so you can write the
  document to a file or validate responses against it in tests:

  ```sh
  mix openapi.dump MyAppWeb.RestRouter.OpenApi --pretty -o priv/openapi.json
  ```

Everything below changes only the document, never the wire format.

## What you can customize

| Document element | Where it comes from | How to override |
|---|---|---|
| `info` | `title: "AshRest API"`, `version: "0.1.0"` | router `open_api_info:` |
| operation `operationId` | the route name, e.g. `"post.get"` | route `name` |
| operation `summary` | generated, e.g. `"Fetch a post"` | route `summary` |
| operation `description` | the Ash action's `description` | route `description` |
| operation `tags` | the resource tag (its `type`) | route `tags`, or `open_api.tag` for the whole resource |
| operation `deprecated` | not set | route `deprecated? true` |
| request body description | not set | route `request_body_description` |
| success response description | generated, e.g. `"The created record."` | route `response_description` |
| path / query parameter descriptions | `id`: generated; query params: the Ash argument or attribute `description` | route `parameter_descriptions` |
| top-level `tags` | every tag in use | `open_api.tag_description` adds a description |
| component schema names | camelized `type`: `Post`, `PostList`, `PostFilter` | `open_api.schema_name` |
| resource schema description | the Ash resource `description` | `open_api.description` |
| field descriptions | the Ash `description` of attributes, calculations, aggregates and relationships | set them in Ash |
| request body field descriptions | the Ash `description` of action arguments and accepted attributes | set them in Ash |
| anything else (servers, security schemes, `x-` extensions) | not generated | router `modify_open_api/1` |

## Documenting an endpoint

Every route takes documentation options. A route without a `description` uses its Ash action's
`description`, so documenting the action once documents every route that calls it.

```elixir
rest do
  base "/posts"

  routes do
    get :read, parameter_descriptions: [id: "The post's UUID"]
    post :create, request_body_description: "The post to create."

    route :post, "/:id/publish", :publish do
      summary "Publish a post"

      description """
      Marks the post as published and stamps `published_by`.
      Publishing an already published post is a no-op.
      """

      response_description "The published post, with `meta.published_by`."
      parameter_descriptions id: "The post's UUID"
      tags ["Posts", "Publishing"]
    end

    index :legacy_list, route: "/legacy", name: "post.legacy", deprecated?: true
  end
end
```

`parameter_descriptions` keys must be path parameters of the route (`:id`, or any `:param`
segment) or entries of its `query_params`; anything else is a compile-time error.

Descriptions set in Ash flow into the document on their own:

```elixir
resource do
  description "A blog post."
end

attributes do
  attribute :title, :string, public?: true, description: "The headline of the post."
end

actions do
  action :word_count, :integer do
    description "Counts the words in a text."
    argument :text, :string, allow_nil?: false, description: "The text to count words in."
  end
end
```

## Naming and describing a resource

The `open_api` section inside `rest` sets the resource's tag and schema names:

```elixir
rest do
  type "comment"
  base "/comments"

  open_api do
    tag "Comments"
    tag_description "Reader comments on posts."
    schema_name "BlogComment"
    description "A reader's comment on a post."
  end
end
```

- `tag` is the default tag of every operation of the resource. Without it, the tag is the `type`.
- `tag_description` describes the tag in the document's top-level `tags` list.
- `schema_name` names the record schema and derives `BlogCommentList`, `BlogCommentFilter` and
  `BlogCommentUnpaginatedList` from it. It may contain letters, digits, `.`, `_` and `-`. Two
  resources of one router resolving to the same name raise an `ArgumentError` when the document
  is built.
- `description` overrides the Ash resource `description` for the schema.

## Document info

`open_api_info` keys are camelized and nested keyword lists become objects:

```elixir
use AshRest.Router,
  domains: [MyApp.Blog],
  open_api_info: [
    title: "Blog API",
    version: "1.0.0",
    description: "Everything about the blog.",
    terms_of_service: "https://example.com/terms",
    contact: [name: "API team", email: "api@example.com"],
    license: [name: "MIT", url: "https://opensource.org/licenses/MIT"]
  ]
```

## Changing anything else

Override `modify_open_api/1` in the router. It receives the finished document, a map with string
keys, and returns the document to serve:

```elixir
defmodule MyAppWeb.RestRouter do
  use AshRest.Router, domains: [MyApp.Blog]

  @impl AshRest.Router
  def modify_open_api(spec) do
    spec
    |> Map.put("servers", [%{"url" => "https://api.example.com"}])
    |> put_in(["components", "securitySchemes"], %{
      "bearer" => %{"type" => "http", "scheme" => "bearer"}
    })
    |> Map.put("security", [%{"bearer" => []}])
  end
end
```

`oaskit` validates the final document against the OpenAPI 3.1 schema when it builds the spec, so a
broken modification fails loudly at boot or in `mix openapi.dump`.
