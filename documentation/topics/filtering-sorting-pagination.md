<!--
SPDX-FileCopyrightText: 2026 ash_rest contributors

SPDX-License-Identifier: MIT
-->

# Filtering, sorting and pagination

List routes (`index`, to-many `related`, and `route`s to read actions) take four query
parameters: `filter`, `sort`, `page` and `include`. Routes that return one record take only
`include`. Routes that return a raw value take none. Anything else in the query string, except a
route's own `query_params`, is a `400 unsupported_query_parameter`. In particular, sparse
fieldsets (`fields=...`) are not supported: every response carries the default fields.

All names in the query string are wire names: `field_names` renames apply, and internal names of
renamed fields are rejected.

## Default fields

A record includes every public attribute, every aggregate and every public calculation that
takes no required arguments. Embedded resources, typed maps and unions are rendered in full.
Relationships are only present when requested with `include`.

## Filter

Filters use the "deep object" query syntax:

```
filter[<field>]=<value>                 # equality
filter[<field>][<operator>]=<value>
```

Conditions on several fields must all match:

```
GET /posts?filter[score][gte]=3&filter[status]=draft
```

Values arrive as strings and are cast with the field's type, so `filter[score][gte]=3` compares
integers and `filter[created_at][gte]=2026-01-01T00:00:00Z` compares datetimes. A value that
does not cast is a `400 invalid_filter_value` whose detail points at the value:

```json
{
  "error": {
    "code": "invalid_filter_value",
    "details": [
      {"code": "invalid_filter_value", "field": "filter.score.eq", "message": "Invalid filter value"}
    ],
    "message": "Invalid filter value",
    "status": 400
  }
}
```

### Operators

| operator | also accepted as | example |
|---|---|---|
| `eq` | the bare value | `filter[title]=Hello`, `filter[title][eq]=Hello` |
| `not_eq` | | `filter[status][not_eq]=draft` |
| `greater_than` | `gt` | `filter[score][gt]=3` |
| `greater_than_or_equal` | `gte` | `filter[score][gte]=3` |
| `less_than` | `lt` | `filter[score][lt]=3` |
| `less_than_or_equal` | `lte` | `filter[score][lte]=3` |
| `in` | | `filter[title][in][]=A&filter[title][in][]=B` |
| `is_nil` | | `filter[body][is_nil]=true` |
| `contains` (strings) | | `filter[title][contains]=ell` |

Ordering operators are only available on types that can be ordered (not on booleans, for
example). The OpenAPI document lists the operators of every field in the `<Type>Filter`
component. `in` takes a list, written with the `[]` suffix once per value; `filter[title][in]=A,B`
is a `400 invalid_filter_value`.

An unknown field is a `400 unknown_field` (detail field `filter.<name>`), an unknown operator
a `400 unknown_filter_operator`.

### Calculations, aggregates and relationships

Calculations and aggregates filter like attributes:

```
GET /posts?filter[title_length][gt]=1&filter[comment_count][eq]=0
```

Relationships nest a filter on the related resource:

```
GET /posts?filter[author][name]=Ada
```

The fields of embedded resources and typed maps cannot be filtered individually:
`filter[settings][color]=red` is a `400 unknown_filter_operator`.

### `not`, `and`, `or`

`not` negates a nested filter:

```
GET /posts?filter[not][title]=B
```

`and` and `or` take a *list* of filters, written with an index per entry:

```
GET /posts?filter[or][0][title]=A&filter[or][1][score][gte]=5
GET /posts?filter[and][0][score][gte]=3&filter[and][1][or][0][title]=B&filter[and][1][or][1][title]=C
```

Any object whose keys are all non-negative integers is read as a list, ordered by index, at any
depth of the filter. Indexes need not be contiguous. The unindexed form
(`filter[or][][title]=A&filter[or][][score]=5`) is **not** supported: Plug merges the entries
into a single object, so the two conditions would become one `and`.

### Disabling filters

`enable_filter? false` on an `index` or `related` route rejects any `filter` with
`400 filter_not_supported`, and the OpenAPI document omits the parameter.

## Sort

`sort` is a comma-separated list of fields. A `-` prefix sorts descending:

```
GET /posts?sort=-created_at,title
```

Attributes, aggregates and calculations without required arguments can be sorted on. Sorting by
a relationship path (`sort=author.name`) is not supported (`400 unknown_field`). An empty
`sort=` means no sort. `sort` must be a plain string: `sort[]=title` is a `400 invalid_sort`.
`enable_sort? false` on an `index` or `related` route rejects `sort` with
`400 sort_not_supported`.

A `+` in a query string decodes to a space, so do not prefix ascending fields with `+`.

## Pagination

Pagination follows the read action's `pagination` configuration.

```elixir
read :read do
  primary? true
  pagination offset?: true, keyset?: true, countable: true, default_limit: 20, required?: false
end
```

| parameter | value | |
|---|---|---|
| `page[limit]` | non-negative integer | page size |
| `page[offset]` | non-negative integer | offset pagination: records to skip |
| `page[after]` | cursor | keyset pagination: records after this cursor |
| `page[before]` | cursor | keyset pagination: records before this cursor |
| `page[count]` | `true` / `false` | include the total `count` (countable actions only) |

Malformed values are rejected before the action runs, with a detail on the page key:

```json
{
  "error": {
    "code": "invalid_pagination",
    "details": [
      {"code": "invalid_pagination", "field": "page.limit", "message": "must be a non-negative integer"}
    ],
    "message": "page[limit] must be a non-negative integer",
    "status": 400
  }
}
```

Any other `page[...]` key, or `page=3`, is also `invalid_pagination`.

### When a response is paginated

- If the action requires pagination (`required?: true`, Ash's default when `pagination` is
  declared), every response is a page, sized by `default_limit` unless `page[limit]` is given.
- If pagination is optional (`required?: false`; also the case for the `read` action generated
  by `defaults [:read]`), a request without `page` returns every record as `{"data": [...]}`,
  and a request with `page` returns a page.
- If the action does not paginate, `page` is a `400 pagination_not_supported`.
- If the route has `paginate? false`, `page` is a `400 unsupported_query_parameter` and the
  read runs without a page. Pair it with an action whose pagination is optional
  (`required?: false`); a read action that requires pagination still answers with its default
  page.

### Mixed pagination

When the action supports both styles, a request with `page[after]` or `page[before]` is a keyset
page and any other paginated request is an offset page. Ash decides this, and the offset page
carries no cursors (ash_rpc does not expose the records' keysets on offset pages), so a client
cannot switch from offset to keyset pagination mid-way. To get keyset pages from the first
request on, declare keyset-only pagination (`pagination keyset?: true, ...`) or make keyset the
default for mixed actions application-wide:

```elixir
config :ash, default_page_type: :keyset
```

### Offset pages

`GET /notes/paged?page[limit]=2&page[count]=true&sort=title`:

```json
{
  "count": 3,
  "data": [
    {"id": "836d729d-9c5e-45a7-9493-16ca4d16e0e3", "pinned": false, "title": "A", "type": "note"},
    {"id": "45f62052-c26a-4414-82ec-ff922b0ec2af", "pinned": true, "title": "B", "type": "note"}
  ],
  "has_more": true,
  "limit": 2,
  "offset": 0
}
```

`count` is present only when `page[count]=true`. Fetch the next page with
`page[offset]=<offset + limit>` while `has_more` is `true`.
`GET /notes/paged?page[limit]=2&page[offset]=2&sort=title`:

```json
{
  "data": [
    {"id": "725481e4-2843-4f64-8137-dc8ac4c84873", "pinned": false, "title": "C", "type": "note"}
  ],
  "has_more": false,
  "limit": 2,
  "offset": 2
}
```

### Keyset pages

Keyset pages carry cursors instead of `limit`/`offset`.
`GET /posts?page[limit]=2&page[count]=true&sort=title`:

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

then `GET /posts?page[limit]=2&sort=title&page[after]=g2wAAAACbQAAAAZTZWNvbmRt...`:

```json
{
  "data": [
    {
      "author_id": "19ccd54d-ddf5-44bc-adc8-15ea2085d4c4",
      "body": null,
      "created_at": "2026-11-12T03:21:13.519861Z",
      "id": "b22ee6a7-8a3d-484e-b06b-9ff1fbe63293",
      "status": "draft",
      "title": "Third",
      "type": "post"
    }
  ],
  "has_more": false,
  "next_cursor": null,
  "prev_cursor": "g2wAAAACbQAAAAVUaGlyZG0AAAAkYjIyZWU2YTctOGEzZC00ODRlLWIwNmItOWZmMWZiZTYzMjkzag=="
}
```

Cursor rules:

- `next_cursor` is the cursor to pass as `page[after]`, `prev_cursor` the one to pass as
  `page[before]`. Either is `null` when there is nothing in that direction.
- On the first page (no `after`/`before`), `prev_cursor` is `null`, and `next_cursor` is set
  when `has_more` is `true`.
- Paging forward (`page[after]`), `prev_cursor` is always set, `next_cursor` only when
  `has_more` is `true`.
- Paging backward (`page[before]`), `has_more` tells whether there are more records *before*
  the page: `prev_cursor` is set only when it is `true`, and `next_cursor` is always set.
- An empty page has no cursors.
- A cursor encodes the sort values of a record. Send the same `sort` and `filter` with every
  page; a cursor that cannot be decoded is a `400 invalid_keyset`.

### Related routes

To-many `related` routes paginate the related records according to the **relationship's read
action** (the relationship's `read_action`, else the destination's primary read), not the
route's action: offset pages with `page[limit]`/`page[offset]`, keyset pages with
`page[after]`/`page[before]`, and `count`, whatever that action allows. The default read action
generated by `defaults [:read]` supports both. A cursor on a relationship whose read action has
no keyset pagination is a `400 invalid_pagination` (detail `page.after`/`page.before`).

Ash only paginates a relationship load with a limit: without `page[limit]`, the read action's
`default_limit` is used, else its `max_page_size` (Ash's default is 250).

## Include

`include` nests relationships in each returned record. It is a comma-separated list of
relationship paths, with dots for nested relationships:

```
GET /posts/:id?include=author,comments.author
```

- Every path must be in the resource's `includes` tree; anything else is a
  `400 invalid_include` naming the path (`"comments.post cannot be included"`).
- To-one relationships render as an object or `null`, to-many relationships as an array.
  Included records carry their `"type"` and their default fields.
- Included relationships are not paginated, filtered or sorted; use a `related` route for that.
- `include` works on `get`, `index`, `post`, `patch`, `delete`, `related` and `route`s that
  return records. On a `related` route it is relative to the related records, limited to the
  subtree of `includes` under the relationship.
