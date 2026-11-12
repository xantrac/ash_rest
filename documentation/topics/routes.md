<!--
SPDX-FileCopyrightText: 2026 ash_rest contributors

SPDX-License-Identifier: MIT
-->

# Routes

Routes are declared per resource, inside `rest do routes do ... end end`. Every path is relative
to the resource's `base`, and the router serves the routes of every resource in its domains.

```elixir
rest do
  type "post"
  base "/posts"
  includes author: [], comments: [:author]
  field_names inserted_at: "created_at"
  argument_names publish: [notify?: "notify"]

  routes do
    get :read                                  # GET    /posts/:id
    index :read                                # GET    /posts
    post :create                               # POST   /posts
    patch :update                              # PATCH  /posts/:id
    delete :destroy                            # DELETE /posts/:id
    related :comments, :read                   # GET    /posts/:id/comments
    route :post, "/:id/publish", :publish      # POST   /posts/:id/publish
  end
end
```

## Resource options

| option | default | |
|---|---|---|
| `base` | required | path prefix of every route, e.g. `"/posts"` |
| `type` | underscored module name | value of the `"type"` key of every record |
| `includes` | `[]` | relationships that may be requested with `?include=`, as a keyword tree |
| `field_names` | `[]` | wire names of fields, e.g. `[inserted_at: "created_at"]` |
| `argument_names` | `[]` | wire names of action arguments, per action, e.g. `[publish: [notify?: "notify"]]` |
| `include_nil_values?` | `true` | when `false`, keys whose value is `null` are left out of records |

Renames apply everywhere a client sees the name: request bodies, response bodies, `filter`,
`sort` and the OpenAPI document. The internal name is not accepted once a field is renamed:
with `field_names inserted_at: "created_at"`, `sort=-inserted_at` is a `400 unknown_field`.

With `include_nil_values? false` and `field_names body: "text", pinned?: "pinned"`, a note
without a body renders without a `text` key:

```json
{"id": "b2281813-bc39-45e0-8906-b0b0ee017999", "pinned": true, "priority": 2, "title": "Beta", "type": "note"}
```

## Common route options

Every route kind takes these options:

| option | default | |
|---|---|---|
| `route` | depends on the kind | path relative to `base`; may contain `:param` segments |
| `name` | `"<type>.<kind>"` | entrypoint name and OpenAPI `operationId`; unique per resource |
| `description` | the action's description | OpenAPI operation description |
| `primary?` | `false` | marks the route to link to by default; informational in this version |
| `query_params` | `[]` | action inputs read from the query string (see below) |
| `metadata` | none | `fn subject, result, request -> map end`, see below |
| `modify_conn` | none | `fn conn, subject, result, request -> conn end`, see below |
| `enable_filter?` | `true` | accept `filter` (`index` and `related` routes) |
| `enable_sort?` | `true` | accept `sort` (`index` and `related` routes) |

Default names are `"post.get"`, `"post.index"`, `"post.post"`, `"post.patch"`, `"post.delete"`,
`"post.related.comments"` and, for `route`, `"post.<action>"`. Two routes of the same kind on one
resource need explicit names:

```elixir
index :read
index :published, route: "/published", name: "post.published"
```

Compile-time checks reject routes whose action does not exist, is not public or has the wrong
type, `read_action`s that are not reads, `related` routes for unknown or private relationships,
includes of unknown or private relationships, duplicate names, two routes with the same method
whose paths only differ in parameter names, and routes addressing one record (`get`, `patch`,
`delete`, `related`) on resources without a single-attribute primary key.

### Path matching

Paths are matched segment by segment. Literal segments win over `:param` segments, so
`GET /posts/keyset` reaches `index :keyset, route: "/keyset"` rather than `get :read`
(`/posts/:id`). Parameter values are URL-decoded. A request that matches no route is a `404`:

```json
{"error": {"code": "no_route_found", "message": "No route found for GET /nothing/here", "status": 404}}
```

## `get`

`GET <base>/:id` (option `route`, default `"/:id"`). Reads one record by primary key with the
given read action. Accepts `include`. Responds `200` with the record, `404 not_found` when no
record matches (including when the id is not a valid primary key value, e.g. not a UUID).

```elixir
get :read
get :read_with_secrets, route: "/:id/full", name: "post.full"
```

## `index`

`GET <base>` (default `"/"`). Lists records with a read action. Accepts `filter`, `sort`,
`page` and `include` (see [Filtering, sorting and pagination](filtering-sorting-pagination.md)).
Responds `200` with `{"data": [...]}`, plus page keys when the request is paginated.

Extra option: `paginate?` (default `true`), whether the route paginates when the action supports
pagination. With `paginate?: false`, `page` is a `400 unsupported_query_parameter`, the read runs
without a page, and the OpenAPI document omits the `page` parameter. Use it with actions whose
pagination is optional (`required?: false`): a read action that requires pagination still
answers with its default page.

```elixir
index :read
index :keyset, route: "/keyset", name: "post.keyset"
```

## `post`

`POST <base>` (default `"/"`). Runs a create action with the JSON body as input. Responds `201`
with the created record. Accepts `include` to nest relationships of the created record.

## `patch`

`PATCH <base>/:id` (default `"/:id"`). Looks the record up by primary key, then runs an update
action with the body as input. Responds `200` with the updated record, `404 not_found` when no
record matches.

Extra option: `read_action`, the read action used for the lookup (default: the primary read).
Records the read action does not return are `404`, which makes it a convenient way to scope what
can be updated:

```elixir
patch :update
patch :update, route: "/:id/pinned", name: "note.update_pinned", read_action: :pinned
```

## `delete`

`DELETE <base>/:id` (default `"/:id"`). Looks the record up like `patch` (same `read_action`
option) and runs a destroy action. Responds `200` with the deleted record. A body, if sent, is
the destroy action's input.

Fields that need the record to still exist, such as aggregates, may be missing from the deleted
record when the data layer destroys atomically.

## `related`

`GET <base>/:id/<relationship>` (default `"/:id/<relationship>"`). Returns the records of a
relationship of one record.

```elixir
related :comments, :read     # GET /posts/:id/comments
related :author, :read       # GET /comments/:id/author
```

The second argument is a read action **on this (the source) resource**: AshRest reads the parent
record with it, by primary key, and loads the relationship. Two consequences:

- The parent's authorization applies. If the actor cannot read the post, `/posts/:id/comments`
  is a `404` (or `403`), even if the comments are readable.
- The related records are loaded through the relationship, with the relationship's (or the
  destination's primary) read action.

To-many relationships respond with a list and accept `filter`, `sort`, `page` (offset style:
`limit`, `offset`, `count`) and `include`:

```json
{
  "data": [
    {
      "author_id": "1758a3af-e8a5-4f41-8fc5-e207a3c0bb70",
      "body": "Nice",
      "id": "069def0a-0e51-496d-b8ca-5d7bf3cc6b82",
      "post_id": "3396a829-45a1-43bb-a9c2-8532118029f0",
      "rating": 5,
      "type": "comment"
    }
  ],
  "has_more": true,
  "limit": 1,
  "offset": 0
}
```

To-one relationships respond with the related record, or `null` when there is none (status
`200` in both cases):

```json
{"email": null, "id": "e4b82a84-2a8f-4307-98c9-034383554202", "name": "Ada", "profile": null, "type": "author"}
```

A missing parent is `404 not_found`. `include` on a related route is relative to the related
records, and only the subtree of the parent's `includes` under that relationship is allowed:
with `includes comments: [:author]` on Post, `GET /posts/:id/comments?include=author` is
allowed and `?include=post` is a `400 invalid_include`.

## `route`

`route method, path, action` maps any method and path to any action. `method` is one of `:get`,
`:post`, `:put`, `:patch`, `:delete`; `path` is required and relative to `base`. The response
depends on the action type:

| action type | input | response |
|---|---|---|
| generic action (`action`) | body + path params + `query_params` | the return value as JSON (`200`) |
| `read` | path params + `query_params` as arguments; `filter`/`sort`/`page`/`include` from the query | a list, like `index`; with `get? true` one record like `get` (`404 not_found` when none matches, only `include` accepted) |
| `create` | body + path params + `query_params` | the created record (`200`) |
| `update` / `destroy` | body + path params + `query_params` | the record (`200`) |

**Generic actions** return their value as is:

```elixir
route :get, "/word_count", :word_count, query_params: [:text]
```

`GET /posts/word_count?text=one%20two%20three` responds `3`.

- `wrap_in_result?: true` wraps the value: `{"result": {"total": 42}}`. Use it for values that
  are not objects if your clients expect an object.
- An action without a return type responds `{"success": true}`.
- An action returning a resource that is exposed through AshRest (`:struct` with
  `instance_of`) responds with the record, `"type"` included, and accepts `include`.

**Update and destroy actions** address one record when the path has an `:id` segment: the
record is looked up by primary key, and the response is the record with the action's metadata
under `"meta"`:

```elixir
route :post, "/:id/publish", :publish
```

```json
{
  "author_id": "1758a3af-e8a5-4f41-8fc5-e207a3c0bb70",
  "body": null,
  "comment_count": 0,
  "content": null,
  "created_at": "2026-11-12T03:18:30.642395Z",
  "id": "479e6274-ffb6-4de1-a786-dc2419012f87",
  "meta": {"published_by": "ash_rest"},
  "published?": true,
  "score": 5,
  "settings": null,
  "status": "published",
  "title": "Second",
  "title_length": 6,
  "type": "post"
}
```

**Path params** other than `:id` on update/destroy routes are merged into the action input, as
are all path params of generic, create and read routes:

```elixir
route :post, "/titled/:title", :create, name: "note.create_titled"
```

`POST /notes/titled/From%20path` with `{"text": "t"}` creates a note titled `From path`.

## `query_params`

`query_params` lists action inputs (arguments, or accepted attributes) that a `route` reads
from the query string instead of the body, by their wire name (after `argument_names`). Values
arrive as strings and are cast by the action input's type. Query parameters that are neither
listed nor part of the route kind's own parameters (`filter`, `sort`, `page`, `include`) are
rejected with `400 unsupported_query_parameter`.

```elixir
route :get, "/search", :search, query_params: [:q]
```

`GET /notes/search?q=lph` runs the `search` read action with `q: "lph"`.

## `metadata` and `modify_conn`

Both functions receive:

- `subject`: a map with `:actor`, `:tenant`, `:resource` and `:action` (the action name).
- `result`: what is about to be rendered, with wire names and `"type"` already applied: the
  record map (or `nil` for an empty to-one `related` route), the list of records (for a page,
  the records of the page, not the wrapper), or the raw return value of a generic action.
- `request`: the `Plug.Conn` of the request.

`metadata` returns a map whose keys become strings under `"meta"`:

- on a record, merged with the action's own metadata (route keys win),
- on a list, as a top-level `"meta"` key of the wrapper,
- only when non-empty. A return value that is not a map is ignored.

It is not called for generic actions that respond with a raw value or `{"success": true}`, nor
for error responses.

```elixir
index :read,
  metadata: fn _subject, records, _request -> %{returned: length(records)} end
```

```json
{
  "data": [
    {"id": "b2281813-bc39-45e0-8906-b0b0ee017999", "pinned": true, "priority": 2, "title": "Beta", "type": "note"},
    {"id": "e149e7c7-75b6-42a2-b51e-1100e2a02e7c", "pinned": false, "text": "hello", "title": "Alpha", "type": "note"}
  ],
  "meta": {"returned": 2}
}
```

`modify_conn` returns the conn to respond with. It runs on every successful response, just
before the body is sent, which makes it the place for response headers:

```elixir
index :read,
  modify_conn: fn conn, _subject, records, _request ->
    Plug.Conn.put_resp_header(conn, "x-note-count", to_string(length(records)))
  end
```

## Statuses

| route | success |
|---|---|
| `post` | `201` |
| everything else | `200` |

Errors are described in [Errors](errors.md).
