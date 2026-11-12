<!--
SPDX-FileCopyrightText: 2026 ash_rest contributors

SPDX-License-Identifier: MIT
-->

# Changelog

All notable changes to this project are documented in this file.
The format follows [Keep a Changelog](https://keepachangelog.com/en/1.1.0/).

## v0.1.0 (unreleased)

First version: a flat, Stripe-style REST API for Ash resources, built on `ash_rpc`.

### Added

- `AshRest` resource extension: `rest` section with `type`, `base`, `includes`, `field_names`,
  `argument_names`, `include_nil_values?`, and `get`, `index`, `post`, `patch`, `delete`,
  `related` and `route` routes with `name`, `description`, `query_params`, `metadata`,
  `modify_conn`, `read_action`, `paginate?`, `enable_filter?`, `enable_sort?` and
  `wrap_in_result?` options.
- Compile-time verification of route actions, includes, overlapping routes, route names and
  primary keys.
- `AshRest.Domain` extension with `error_handler` and `show_raised_errors?`.
- `AshRest.Router`: a Plug serving every route of the given domains, mountable with Phoenix
  `forward`, acting as the `AshRpc.Profile` of its requests.
- Wire format: bare records with `"type"`, inline includes, `{"data": [...]}` lists with offset
  (`limit`/`offset`) or keyset (`next_cursor`/`prev_cursor`) pagination and `count`, action
  and route metadata under `"meta"`, raw generic action results.
- Query parameters: deep-object `filter`, `sort`, `page`, `include`, and per-route
  `query_params`.
- Error envelope `{"error": {"status", "code", "message", "details"}}` with status mapping and
  local `400`/`404`/`413`/`415` errors.
- OpenAPI 3.1 document generated from routes and resource types, served at `/openapi.json` with
  a Redoc page at `/docs`, and an `oaskit` spec module per router (`<Router>.OpenApi`) for
  `mix openapi.dump` and response validation.
- `AshRest.Test` request and assertion helpers, with optional OpenAPI response validation.
- OpenAPI customization: route `summary`, `request_body_description`, `response_description`,
  `parameter_descriptions`, `tags` and `deprecated?`; a resource `open_api` section with `tag`,
  `tag_description`, `schema_name` and `description`; top-level `tags`; camelized and nested
  `open_api_info` keys (`terms_of_service`, `contact`, `license`); and an overridable
  `modify_open_api/1` router callback. Route descriptions fall back to the Ash action's.

### Fixed

- `filter[or]`/`filter[and]` can be written with indexes (`filter[or][0][title]=A&filter[or][1][title]=B`):
  integer-keyed objects become lists at any depth of the filter.
- `paginate? false` on `index` routes rejects `page` (`400 unsupported_query_parameter`) and runs
  the read unpaginated.
- `enable_filter?`/`enable_sort?` are honoured on `related` routes (`400 filter_not_supported` /
  `sort_not_supported`, as on `index` routes).
- Error details of `related` routes name the query parameter (`filter.nope`), not the internal
  relationship envelope (`comments.filter.nope`).
- A generic `route` to a `get? true` read action renders one record (or `404 not_found`) instead
  of crashing.
- `query_params` are passed as action input on `get`, `index`, `related`, `post`, `patch` and
  `delete` routes too.
- A write request body sent without a `Content-Type`, or with a non-JSON content type already
  parsed by an upstream `Plug.Parsers` (form bodies behind a Phoenix endpoint), is a `415`.
  `application/*+json` and `application/json; charset=...` are accepted.
- With `show_raised_errors? true`, the forbidden exceptions ash_rpc names after their module
  (`policy`, ...) are rendered as `403 forbidden` again.
- `conn.private.oaskit.operation_id` is set before the body is parsed, so `400 invalid_body` and
  `413 request_too_large` can be validated against the OpenAPI operation.
- An empty `sort=` means no sort instead of a `400`.
- `page[after]`/`page[before]` work on to-many `related` routes whose relationship read action
  supports keyset pagination (`400 invalid_pagination` otherwise); a related page without
  `page[limit]` uses the read action's `default_limit`, else its `max_page_size`, instead of
  being silently ignored.
- When an error handler drops every error, the response is a `500 internal_error`
  ("An error occurred") instead of `unknown_error`.
