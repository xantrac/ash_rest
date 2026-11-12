<!--
SPDX-FileCopyrightText: 2026 ash_rest contributors

SPDX-License-Identifier: MIT
-->

# Getting started

This guide adds a REST API to an existing Ash application: one resource, one router, a Phoenix
mount and a test.

## 1. Install

AshRest is not on Hex yet. Add it, and optionally `oaskit` for the OpenAPI document, to
`mix.exs`:

```elixir
def deps do
  [
    {:ash_rest, github: "xantrac/ash_rest"},
    {:oaskit, "~> 0.18"}
  ]
end
```

AshRest depends on [`ash_rpc`](https://github.com/ash-project/ash_rpc) through a pinned git
reference; Mix fetches it for you. Then add `:ash_rest` to `import_deps` in `.formatter.exs`:

```elixir
[
  import_deps: [:ash, :ash_rest],
  # ...
]
```

## 2. Expose a resource

Add the `AshRest` extension and a `rest` block. `base` is required; everything else has a
default.

```elixir
defmodule MyApp.Blog.Post do
  use Ash.Resource,
    domain: MyApp.Blog,
    data_layer: AshPostgres.DataLayer,
    extensions: [AshRest]

  rest do
    # defaults to the underscored module name: "post"
    type "post"
    base "/posts"

    routes do
      get :read
      index :read
      post :create
      patch :update
      delete :destroy
    end
  end

  # attributes, relationships, actions ...
end
```

Only public attributes, calculations, aggregates and relationships are part of the API, and only
public actions can be routed. AshRest checks at compile time that every route points to an
existing public action of the right type.

The domain can carry an optional `rest` section with domain-wide error options (see
[Errors](errors.md)):

```elixir
defmodule MyApp.Blog do
  use Ash.Domain, extensions: [AshRest.Domain]

  resources do
    resource MyApp.Blog.Post
  end
end
```

## 3. Create a router

```elixir
defmodule MyAppWeb.RestRouter do
  use AshRest.Router,
    domains: [MyApp.Blog],
    otp_app: :my_app,
    open_api_info: [title: "My App API", version: "1.0.0"]
end
```

Router options:

| option | default | |
|---|---|---|
| `:domains` | required | domains whose `AshRest` resources are served |
| `:otp_app` | `:ash_rest` | passed to the `Ash.Info.Manifest` generator |
| `:open_api` | `"/openapi.json"` with oaskit, else `false` | path of the OpenAPI document |
| `:docs` | `"/docs"` with oaskit and `:open_api`, else `false` | path of a Redoc page |
| `:open_api_info` | `[]` | `:title`, `:version`, `:description` of the document |
| `:error_handler` | the domain's, else none | see [Errors](errors.md) |
| `:show_raised_errors?` | the domain's, else `false` | see [Errors](errors.md) |

The router is also the `AshRpc.Profile` its requests run through. The API description (an
`Ash.Info.Manifest` decorated by `ash_rpc`) is built on the first request and cached in
`:persistent_term`. After hot code reloading in development, call
`AshRest.Manifest.clear(MyAppWeb.RestRouter)` if a change does not show up.

## 4. Mount it

The router is a `Plug`. In Phoenix, `forward` a path to it:

```elixir
# lib/my_app_web/router.ex
pipeline :api do
  plug :accepts, ["json"]
end

scope "/api" do
  pipe_through :api
  forward "/", MyAppWeb.RestRouter
end
```

Without Phoenix, run it directly with Bandit or Cowboy:

```elixir
children = [{Bandit, plug: MyAppWeb.RestRouter, port: 4001}]
```

The router parses JSON bodies itself. If an upstream `Plug.Parsers` (such as the one in a
Phoenix endpoint) already parsed the body, the parsed params are used.

## 5. Actors and tenants

AshRest does not authenticate. It reads the actor and the tenant from the conn with
`Ash.PlugHelpers.get_actor/1` and `Ash.PlugHelpers.get_tenant/1`, so authorize requests by
setting them in a plug before the router:

```elixir
pipeline :api do
  plug :accepts, ["json"]
  plug :load_from_bearer   # AshAuthentication
  plug :set_actor, :user
end
```

or by hand:

```elixir
plug :put_actor

defp put_actor(conn, _opts) do
  user = MyApp.Accounts.user_from_token(conn)
  Ash.PlugHelpers.set_actor(conn, user)
end
```

Policies then apply as usual. A forbidden request is a `403`:

```json
{"error": {"code": "forbidden", "message": "forbidden", "status": 403}}
```

## 6. Try it

```sh
curl -s localhost:4000/api/posts
curl -s -X POST localhost:4000/api/posts \
  -H 'content-type: application/json' \
  -d '{"title": "Hello"}'
curl -s localhost:4000/api/openapi.json
open http://localhost:4000/api/docs
```

Request bodies must be JSON objects sent as `application/json`; anything else on a write route
is a `415` (see [Errors](errors.md)).

## 7. Test it

`AshRest.Test` calls the router through `Plug.Test`; it needs no endpoint and no Phoenix.
Requests assert the status (default `200`, `201` for `post`) and the JSON content type, and
return the conn with the decoded body in `conn.assigns.json`:

```elixir
defmodule MyApp.PostApiTest do
  use MyApp.DataCase, async: true

  import AshRest.Test

  alias MyAppWeb.RestRouter, as: Router

  test "create, read and list posts" do
    %{"id" => id} =
      Router
      |> post("/posts", %{title: "Hello"})
      |> assert_record(%{"type" => "post", "title" => "Hello"})

    Router
    |> get("/posts/#{id}")
    |> assert_record(%{"id" => ^id})

    Router
    |> get("/posts", query: [filter: [title: "Hello"]])
    |> assert_list([%{"id" => ^id}])
  end

  test "errors" do
    Router
    |> post("/posts", %{}, status: 400)
    |> assert_error_detail("title", "required")

    Router
    |> get("/posts/#{Ash.UUID.generate()}", status: 404)
    |> assert_error(404, "not_found")
  end
end
```

Options include `:actor`, `:tenant`, `:headers`, `:query`, `:content_type`, `:raw_body` and
`:openapi`. To validate every response against the generated OpenAPI document, add this to
`test/test_helper.exs`:

```elixir
AshRest.Test.validate_openapi(true)
```

## Next steps

- [Routes](routes.md): every route type and option.
- [Filtering, sorting and pagination](filtering-sorting-pagination.md): the list query string.
- [Errors](errors.md): the error envelope and status codes.
