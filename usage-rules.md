<!--
SPDX-FileCopyrightText: 2026 ash_rest contributors

SPDX-License-Identifier: MIT
-->

# Rules for working with AshRest

AshRest exposes Ash resources as a flat REST API (bare JSON records, `{"data": [...]}` lists,
`{"error": {...}}` errors) on top of `ash_rpc`, with an OpenAPI 3.1 document via `oaskit`.
It is not AshJsonApi: there are no `attributes`/`relationships` envelopes and no
`application/vnd.api+json`.

## Configuration

- Add `extensions: [AshRest]` to the resource and a `rest` block with a required `base`
  (`base "/posts"`). Optional: `type` (defaults to the underscored module name), `includes`,
  `field_names`, `argument_names`, `include_nil_values?`.
- Declare routes inside `rest do routes do ... end end`: `get`, `index`, `post`, `patch`,
  `delete`, `related :rel, :read`, `route :method, "/path", :action`. Paths are relative to
  `base`.
- Only public actions, attributes, calculations, aggregates and relationships are exposed.
  Mark them `public?: true`; for foreign keys of `belongs_to`, use `attribute_public?: true`.
- Two routes of the same kind on one resource need distinct `name`s.
- Serve resources with a router: `use AshRest.Router, domains: [MyApp.Blog], otp_app: :my_app`.
  Mount it with `forward "/api", MyAppWeb.RestRouter` in Phoenix. Do not write controllers.
- Domain-wide `error_handler` and `show_raised_errors?` go in the domain's `rest` block with
  `extensions: [AshRest.Domain]`, or as router options (router wins).
- Set the actor and tenant with `Ash.PlugHelpers.set_actor/2` / `set_tenant/2` in a plug before
  the router. AshRest has no authentication of its own; policies do the authorization.

## Routes

- `related :comments, :read`: the action is a read action on the **source** resource (the one
  with the `rest` block), used to fetch the parent by id. It is not the destination's action.
- `route` responses depend on the action type: generic actions return their raw value
  (`wrap_in_result?: true` wraps it as `{"result": ...}`, no return type gives
  `{"success": true}`); read actions return a list; create/update/destroy return the record.
  Status is `200` for every route except `post`, which is `201`.
- A `route` to an update or destroy action addresses a record by primary key only if the path
  contains `:id`. Other path params are merged into the action input.
- Use `query_params: [:arg]` on a `route` to read action inputs from the query string; any
  other unknown query parameter is a `400 unsupported_query_parameter`.
- `metadata: fn subject, result, request -> map end` adds `"meta"`; `modify_conn: fn conn,
  subject, result, request -> conn end` changes the response (headers). `result` is the
  rendered record, list of records, or raw value.

## Requests

- Request bodies are JSON objects sent with `content-type: application/json`.
- Use wire names everywhere: `field_names` and `argument_names` renames apply to input, output,
  `filter` and `sort`, and the internal names are rejected.
- Filters: `filter[field]=v` (equality), `filter[field][op]=v` with `eq`, `not_eq`, `gt`/
  `greater_than`, `gte`, `lt`, `lte`, `in` (`filter[f][in][]=a&filter[f][in][]=b`), `is_nil`,
  `contains` (strings); `filter[rel][field]=v` for relationships; `filter[not][field]=v`;
  `filter[or][0][a]=1&filter[or][1][b]=2` for `or`/`and` lists (indexed, never `[]`).
  Do not rely on `and`/`or` lists in query strings.
- Sort: `sort=-created_at,title`. No relationship paths.
- Pagination: `page[limit]`, `page[offset]`, `page[after]`, `page[before]`, `page[count]=true`,
  as allowed by the read action's `pagination`. Follow `next_cursor` with `page[after]` and
  `prev_cursor` with `page[before]`, keeping the same `sort` and `filter`.
- `include=author,comments.author` nests relationships; every path must be in the resource's
  `includes`. There is no `fields` parameter.

## Responses and errors

- A record is a flat object with `"type"`; foreign keys are plain attributes; relationships appear
  only when included. Lists are `{"data": [...]}` plus `has_more`, `count`, `limit`/`offset` or
  `next_cursor`/`prev_cursor` when paginated.
- Errors are `{"error": {"status", "code", "message", "details": [{"field", "code",
  "message"}]}}`. Branch on `code`. `not_found` is 404, `forbidden` 403, `unknown_error` and
  `internal_error` 500, everything else 400; AshRest also sends 404 `no_route_found`,
  413 `request_too_large` and 415 `unsupported_media_type`.

## Testing

- Use `AshRest.Test`: `get/3`, `post/4`, `patch/4`, `put/4`, `delete/3` take the router module,
  assert the status (`:status`, default 200, 201 for `post`) and return the conn with the decoded
  body in `conn.assigns.json` (or `json(conn)`).
- Assert with `assert_record(conn, %{"title" => "x"})`, `assert_list(conn, 2)`,
  `assert_error(conn, 404, "not_found")`, `assert_error_detail(conn, "title", "required")`.
- Pass `actor:` and `tenant:` options instead of building conns by hand.
- With `oaskit`, call `AshRest.Test.validate_openapi(true)` in `test_helper.exs` to validate every
  response against the generated document.

## OpenAPI

- With `oaskit`, the router serves `/openapi.json` and `/docs` and defines `<Router>.OpenApi`.
  Dump it with `mix openapi.dump MyAppWeb.RestRouter.OpenApi --pretty -o priv/openapi.json`.
- `operationId` is the route name (`"post.get"`). Do not edit the generated document; change the
  resources and routes instead.
