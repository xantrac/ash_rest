<!--
SPDX-FileCopyrightText: 2026 ash_rest contributors

SPDX-License-Identifier: MIT
-->

# Errors

## The envelope

Every error response, whatever produced it, has the same shape:

```json
{
  "error": {
    "status": 400,
    "code": "required",
    "message": "attribute title is required",
    "details": [
      {"field": "title", "code": "required", "message": "attribute title is required"}
    ]
  }
}
```

- `status` repeats the HTTP status.
- `code` is a stable, machine-readable string. Branch on it, not on `message`.
- `message` is human-readable, with the error's variables already interpolated.
- `details` has one entry per underlying error. When a request has several problems they are all
  reported, and the top-level `code` and `message` are those of the first one. `details` is left
  out when there is exactly one error and it is not about a particular field.

`POST /posts` with `{"body": 1}` (wrong type, and the required title missing):

```json
{
  "error": {
    "code": "invalid_attribute",
    "details": [
      {"code": "invalid_attribute", "field": "body", "message": "is invalid"},
      {"code": "required", "field": "title", "message": "attribute title is required"}
    ],
    "message": "is invalid",
    "status": 400
  }
}
```

### `details[].field`

`field` is the wire path of what the error is about, joined with dots, or `null`:

| example | meaning |
|---|---|
| `title` | a body key |
| `settings.featured` | a key nested in an embedded resource or map in the body |
| `filter.score.eq` | the value of `filter[score][eq]` |
| `filter.nope` | an unknown field in `filter` |
| `sort.inserted_at` | an entry of `sort` |
| `page.limit` | a `page[...]` key |
| `include` | the `include` parameter |
| `foo` | an unsupported query parameter |

Field names are wire names (`field_names` and `argument_names` renames apply). Use
`assert_error_detail(conn, field, code)` from `AshRest.Test` to assert on them.

## Status codes

The status comes from the `code` of the first error:

| code | status |
|---|---|
| `not_found`, `action_not_found` | `404` |
| `forbidden`, `forbidden_field` | `403` |
| `unknown_error`, `internal_error` | `500` |
| anything else | `400` |

Common codes from running the action:

| code | when |
|---|---|
| `required` | a required attribute or argument is missing |
| `invalid_attribute`, `invalid_argument` | a value does not cast or fails a constraint |
| `unknown_input` | a body key (or nested key) that the action does not accept |
| `invalid_union_input` | a union value that names no member, or several |
| `not_found` | no record with that id (or the route's `read_action` does not return it) |
| `forbidden` | a policy forbids the request |
| `unknown_field`, `unknown_filter_operator`, `invalid_filter_value` | bad `filter` or `sort` |
| `invalid_keyset` | a `page[after]`/`page[before]` cursor that cannot be decoded |
| `filter_not_supported`, `sort_not_supported`, `pagination_not_supported` | the route or action does not take `filter`, `sort` or `page` |
| `unknown_error` | an unexpected exception (see `show_raised_errors?`) |
| `internal_error` | an error ash_rpc could not report (a failing error handler, or a handler that dropped every error) |

## Errors raised by AshRest itself

Some requests are rejected before an action runs. They use the same envelope:

| status | code | when |
|---|---|---|
| `404` | `no_route_found` | no route matches the method and path |
| `400` | `invalid_body` | the body is not valid JSON, or not a JSON object |
| `413` | `request_too_large` | the body is larger than `Plug.Parsers` accepts (8 MB) |
| `415` | `unsupported_media_type` | a `POST`/`PUT`/`PATCH` whose `Content-Type` is not `application/json` (or `application/*+json`), or that sends a body without a `Content-Type` |
| `400` | `unsupported_query_parameter` | a query parameter the route does not take, `fields`, or `page` on a `paginate? false` route |
| `400` | `invalid_pagination` | a malformed `page[...]` value, an unknown `page` key, or a cursor on a `related` route whose read action has no keyset pagination |
| `400` | `filter_not_supported` / `sort_not_supported` | `filter` / `sort` on a `related` route with `enable_filter? false` / `enable_sort? false` (same codes as ash_rpc sends for `index` routes) |
| `400` | `invalid_filter` / `invalid_sort` | `filter` is not an object / `sort` is not a string |
| `400` | `invalid_include` | an `include` path outside the resource's `includes` |

```json
{"error": {"code": "unsupported_media_type", "message": "Request bodies must be sent as application/json", "status": 415}}
```

```json
{"error": {"code": "no_route_found", "message": "No route found for GET /nothing", "status": 404}}
```

An empty body on a write route is accepted and means "no input". The content type is checked
even when an upstream `Plug.Parsers` (a Phoenix endpoint's) has already parsed the body: a
form-encoded body arriving as parsed params is still a `415`.

## Unexpected exceptions and `show_raised_errors?`

By default an exception raised while running an action is logged and answered with a generic
`500`:

```json
{"error": {"code": "unknown_error", "message": "Something went wrong", "status": 500}}
```

With `show_raised_errors? true` the exception's message is sent instead:

```json
{"error": {"code": "unknown_error", "message": "** (RuntimeError) boom", "status": 500}}
```

Set it on the domain or the router (the router wins):

```elixir
# domain
rest do
  show_raised_errors? true
end

# router
use AshRest.Router, domains: [MyApp.Blog], show_raised_errors?: true
```

> #### Development only {: .warning}
>
> `show_raised_errors?` exposes internals. It also changes how every Ash error is rendered:
> ash_rpc then names errors after their exception module and drops their `fields`
> (the raised-error path of `AshRpc.Errors`), so `details[].field` is `null` for validation errors
> (`{"code": "required", "message": "attribute title is required"}` without a `title` field)
> and `details` is left out for single errors. AshRest maps the forbidden exceptions
> (`policy`, `must_pass_strict_check`, `domain_requires_actor`) back to `"forbidden"` / `403`,
> so policy failures keep their status. Keep it off in production.

## Error handlers

An error handler can rewrite or drop errors before they are rendered. It is a module
implementing `AshRpc.ErrorHandler`, or an `{module, function, args}` tuple called as
`apply(module, function, [error, context | args])`:

```elixir
defmodule MyApp.RestErrorHandler do
  @behaviour AshRpc.ErrorHandler

  @impl true
  def handle_error(%{type: "required"} = error, _context) do
    %{error | message: "please provide %{field}", vars: Map.put(error.vars, :field, "it")}
  end

  def handle_error(error, _context), do: error
end
```

Configure it on the domain or on the router (the router wins):

```elixir
# domain
rest do
  error_handler MyApp.RestErrorHandler
end

# router
use AshRest.Router, domains: [MyApp.Blog], error_handler: MyApp.RestErrorHandler
```

The handler receives each error as a map with atom keys: `type` (becomes `code`, and decides the
status), `message` (a template with `%{var}` placeholders), `short_message`, `vars`, `fields`
and `path` (which become `details[].field`). Other keys are not rendered. `context` is the
request's Ash context. With the handler above, `POST /posts` with `{}` responds:

```json
{
  "error": {
    "code": "required",
    "details": [{"code": "required", "field": "title", "message": "please provide it"}],
    "message": "please provide it",
    "status": 400
  }
}
```

Returning `nil` drops an error. If every error of a response is dropped, the client gets a
generic `500 internal_error` with the message `"An error occurred"`.

Handlers apply to the errors of running the action (the Ash errors). Errors that `ash_rpc` finds
while checking the request against the API description before running anything (such as
`unknown_input`, `invalid_union_input`, `filter_not_supported`, `sort_not_supported`,
`pagination_not_supported`) and AshRest's own errors listed above are not passed to the handler.

A resource can also define `handle_rpc_error/2` (same arguments as `handle_error/2`); ash_rpc
calls it before the domain or router handler for errors of that resource.
