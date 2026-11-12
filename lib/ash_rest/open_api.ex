# SPDX-FileCopyrightText: 2026 ash_rest contributors
#
# SPDX-License-Identifier: MIT

defmodule AshRest.OpenApi do
  @moduledoc """
  Builds the OpenAPI 3.1 document of an `AshRest.Router` as a plain map.

  The document describes exactly what the router serves: one operation per
  route (`operationId` is the route name, e.g. `"post.get"`), request bodies
  from the action inputs, `filter`/`sort`/`page` query parameters for routes
  that return lists, `include` for every route that returns records, and
  response schemas in the flat wire format (bare records with a `type`,
  `{"data": [...]}` list envelopes, `{"error": {...}}` errors).

  This module does not depend on `oaskit`; `use AshRest.Router` wraps `spec/1`
  in a `use Oaskit` module when oaskit is available so the document can be
  served, dumped and used for response validation.
  """

  alias Ash.Info.Manifest
  alias AshRest.Manifest, as: RestManifest
  alias AshRest.OpenApi.Schema
  alias AshRest.Resource.Info
  alias AshRest.Resource.Route
  alias AshRpc.Manifest.Custom

  @json "application/json"

  @error_responses %{
    "400" => "BadRequest",
    "403" => "Forbidden",
    "404" => "NotFound",
    "413" => "PayloadTooLarge",
    "415" => "UnsupportedMediaType",
    "500" => "InternalServerError"
  }

  # Methods whose requests carry a body: the router parses it (400 when it is
  # not valid JSON, 413 when too large) and the controller rejects anything
  # that is not JSON (415), whether or not the action takes input.
  @write_methods [:post, :patch, :put]

  @doc """
  The OpenAPI 3.1.0 document of `router`, with string keys.

  `info` defaults to title `"AshRest API"` and version `"0.1.0"`, overridden
  by the router's `:open_api_info` option (`:title`, `:version`, `:description`).
  """
  @spec spec(module()) :: map()
  def spec(router) do
    manifest = RestManifest.get(router)
    reg = Schema.new(manifest)

    {paths, reg} =
      router
      |> RestManifest.routes()
      |> Enum.reduce({%{}, reg}, fn {_domain, resource, route}, {paths, reg} ->
        {operation, reg} = operation(reg, manifest, resource, route)
        path = path_template(route.route)
        method = Atom.to_string(route.method)
        {Map.update(paths, path, %{method => operation}, &Map.put(&1, method, operation)), reg}
      end)

    spec =
      %{
        "openapi" => "3.1.0",
        "info" => info(router),
        "paths" => paths,
        "components" => %{
          "schemas" => Map.merge(Schema.schemas(reg), error_schemas()),
          "responses" => error_response_components()
        }
      }
      |> maybe_put("tags", tags(router, paths))

    modify(router, spec)
  end

  # The router's `modify_open_api/1` runs last, on the finished document.
  defp modify(router, spec) do
    Code.ensure_loaded(router)

    if function_exported?(router, :modify_open_api, 1),
      do: router.modify_open_api(spec),
      else: spec
  end

  defp info(router) do
    overrides =
      router.__ash_rest__(:open_api_info)
      |> Enum.reject(fn {_k, v} -> is_nil(v) end)
      |> Map.new(fn {k, v} -> {camelize(k), info_value(v)} end)

    Map.merge(%{"title" => "AshRest API", "version" => "0.1.0"}, overrides)
  end

  # `contact: [name: "x", email: "y"]` -> `%{"contact" => %{"name" => "x", "email" => "y"}}`
  defp info_value(value) when is_list(value) and value != [] do
    if Keyword.keyword?(value),
      do: Map.new(value, fn {k, v} -> {camelize(k), info_value(v)} end),
      else: value
  end

  defp info_value(%{} = value) when not is_struct(value),
    do: Map.new(value, fn {k, v} -> {camelize(k), info_value(v)} end)

  defp info_value(value), do: value

  # `:terms_of_service` -> `"termsOfService"`; strings are kept as given.
  defp camelize(key) when is_atom(key) do
    [first | rest] = key |> Atom.to_string() |> String.split("_")
    Enum.join([first | Enum.map(rest, &String.capitalize/1)])
  end

  defp camelize(key), do: key

  # One entry per tag used by an operation, described by the resource's
  # `open_api.tag_description` when it declares one.
  defp tags(router, paths) do
    used =
      for {_path, operations} <- paths,
          {_method, operation} <- operations,
          tag <- Map.get(operation, "tags", []),
          into: MapSet.new(),
          do: tag

    descriptions =
      for {_domain, resource, _route} <- RestManifest.routes(router),
          description = Info.open_api_tag_description(resource),
          into: %{},
          do: {Info.open_api_tag(resource), description}

    case Enum.sort(used) do
      [] -> nil
      names -> Enum.map(names, &maybe_put(%{"name" => &1}, "description", descriptions[&1]))
    end
  end

  # `/posts/:id` -> `/posts/{id}`
  defp path_template(route) do
    route
    |> String.split("/", trim: true)
    |> Enum.map_join("/", fn
      ":" <> name -> "{#{name}}"
      literal -> literal
    end)
    |> then(&("/" <> &1))
  end

  defp path_param_names(route) do
    for ":" <> name <- String.split(route, "/", trim: true), do: name
  end

  # -- operations -------------------------------------------------------------

  # Everything an operation is derived from. `kind` mirrors
  # `AshRest.Controller`: `:list` routes take filter/sort/page/include,
  # `:record` routes take include, `:value` routes take neither.
  defp context(manifest, resource, %Route{} = route) do
    res = RestManifest.resource(manifest, resource)
    action = RestManifest.action(manifest, resource, route.action)

    %{
      manifest: manifest,
      resource: resource,
      res: res,
      action: action,
      route: route,
      rest_type: Info.type(resource),
      path_params: path_param_names(route.route),
      kind: kind(manifest, resource, action, route),
      list: list_target(manifest, resource, action, route)
    }
  end

  defp operation(reg, manifest, resource, %Route{} = route) do
    ctx = context(manifest, resource, route)

    {parameters, reg} = parameters(reg, ctx)
    {body, reg} = request_body(reg, ctx)
    {responses, reg} = responses(reg, ctx)

    operation =
      %{
        "operationId" => route.name,
        "tags" => route.tags || [Info.open_api_tag(resource)],
        "summary" => route.summary || summary(route, ctx.rest_type),
        "parameters" => parameters,
        "responses" => responses
      }
      |> maybe_put("description", route.description || (ctx.action && ctx.action.description))
      |> maybe_put("requestBody", body)
      |> maybe_put("deprecated", if(route.deprecated?, do: true))

    {operation, reg}
  end

  defp summary(%Route{type: :get}, type), do: "Fetch a #{type}"
  defp summary(%Route{type: :index}, type), do: "List #{type} records"
  defp summary(%Route{type: :post}, type), do: "Create a #{type}"
  defp summary(%Route{type: :patch}, type), do: "Update a #{type}"
  defp summary(%Route{type: :delete}, type), do: "Delete a #{type}"

  defp summary(%Route{type: :related, relationship: rel}, type),
    do: "Fetch the #{rel} of a #{type}"

  defp summary(%Route{type: :route, action: action}, type), do: "Run #{action} on #{type}"

  defp kind(_manifest, _resource, _action, %Route{type: :index}), do: :list

  defp kind(_manifest, _resource, _action, %Route{type: type})
       when type in [:get, :post, :patch, :delete],
       do: :record

  defp kind(_manifest, resource, _action, %Route{type: :related, relationship: rel}) do
    case Ash.Resource.Info.relationship(resource, rel).cardinality do
      :many -> :list
      :one -> :record
    end
  end

  defp kind(_manifest, _resource, %Manifest.Action{type: :read}, %Route{type: :route}), do: :list

  defp kind(_manifest, _resource, %Manifest.Action{type: type}, %Route{type: :route})
       when type in [:create, :update, :destroy],
       do: :record

  defp kind(manifest, _resource, %Manifest.Action{returns: returns}, %Route{type: :route}) do
    if AshRest.Fields.resource_module(manifest, returns), do: :record, else: :value
  end

  defp kind(_manifest, _resource, nil, _route), do: :value

  # -- parameters -------------------------------------------------------------

  defp parameters(reg, ctx) do
    {path, reg} = path_parameters(reg, ctx)
    {list, reg} = list_parameters(reg, ctx)
    include = include_parameter(ctx)
    {query, reg} = query_parameters(reg, ctx)
    {path ++ list ++ include ++ query, reg}
  end

  defp path_parameters(reg, %{resource: resource, res: res, action: action} = ctx) do
    pk = Info.primary_key(resource)
    pk_field = res && Manifest.Resource.get_field(res, pk)
    inputs = action_inputs(res, action)

    Enum.map_reduce(ctx.path_params, reg, fn name, reg ->
      {schema, reg} =
        cond do
          name == "id" and not is_nil(pk_field) -> Schema.type(reg, pk_field.type, :input)
          match?(%{}, inputs[name]) -> Schema.type(reg, inputs[name].type, :input)
          true -> {%{"type" => "string"}, reg}
        end

      description =
        parameter_description(ctx.route, name) ||
          if name == "id",
            do: "The #{pk} of the #{ctx.rest_type}.",
            else: "Path parameter `#{name}`, merged into the action input."

      param = %{
        "name" => name,
        "in" => "path",
        "required" => true,
        "description" => description,
        "schema" => schema
      }

      {param, reg}
    end)
  end

  # `filter`, `sort` and `page` for routes that return a list.
  defp list_parameters(reg, %{kind: :list, list: %{target: target} = list, route: route} = ctx) do
    target_res = RestManifest.resource(ctx.manifest, target)

    {filter, reg} =
      if route.enable_filter? and target_res do
        {schema, reg} = Schema.filter(reg, target)

        {[
           %{
             "name" => "filter",
             "in" => "query",
             "style" => "deepObject",
             "explode" => true,
             "description" =>
               "Filter the records, e.g. `filter[title][eq]=x` or `filter[title]=x`. " <>
                 "`filter[and]` and `filter[or]` take indexed lists of nested filters " <>
                 "(`filter[or][0][title]=A&filter[or][1][title]=B`), " <>
                 "`filter[not]` a single nested filter (`filter[not][title]=A`).",
             "schema" => schema
           }
         ], reg}
      else
        {[], reg}
      end

    sort =
      if route.enable_sort? and target_res do
        sortable =
          target_res
          |> Manifest.Resource.all_fields()
          |> Enum.filter(& &1.sortable?)
          |> Enum.map(&Schema.client_name(Custom.field_names(target_res), &1.name))

        [
          %{
            "name" => "sort",
            "in" => "query",
            "description" =>
              "Comma-separated sort fields; prefix a field with `-` for descending order " <>
                "(e.g. `-created_at,title`). Sortable fields: " <>
                Enum.map_join(sortable, ", ", &"`#{&1}`") <> ".",
            "schema" => %{"type" => "string"}
          }
        ]
      else
        []
      end

    page =
      case list.pagination do
        %Manifest.Pagination{} = pagination ->
          [
            %{
              "name" => "page",
              "in" => "query",
              "style" => "deepObject",
              "explode" => true,
              "description" => "Pagination, e.g. `page[limit]=20`.",
              "schema" => page_schema(pagination)
            }
          ]

        nil ->
          []
      end

    {filter ++ sort ++ page, reg}
  end

  defp list_parameters(reg, _ctx), do: {[], reg}

  # `include` for every route that returns records.
  defp include_parameter(%{kind: kind, list: %{includes: includes}})
       when kind in [:list, :record] do
    case include_paths(includes) do
      [] ->
        []

      paths ->
        [
          %{
            "name" => "include",
            "in" => "query",
            "description" =>
              "Comma-separated relationship paths to nest in each record. Allowed: " <>
                Enum.map_join(paths, ", ", &"`#{&1}`") <> ".",
            "schema" => %{"type" => "string"}
          }
        ]
    end
  end

  defp include_parameter(_ctx), do: []

  # The resource whose records a route returns, the pagination its `page`
  # parameter follows (`nil` when the response is never a page), and the
  # allowed include tree.
  defp list_target(manifest, resource, _action, %Route{type: :related} = route) do
    rel = Ash.Resource.Info.relationship(resource, route.relationship)
    includes = resource |> Info.includes() |> Keyword.get(route.relationship, [])

    %{
      target: rel.destination,
      pagination: related_pagination(manifest, resource, rel),
      includes: includes
    }
  end

  defp list_target(_manifest, resource, action, %Route{} = route) do
    pagination = if route.paginate? and action, do: action.pagination, else: nil
    %{target: resource, pagination: pagination, includes: Info.includes(resource)}
  end

  # ash_rpc pages a relationship with the relationship's own read action (or
  # the destination's primary read), never with the route's.
  defp related_pagination(manifest, resource, rel) do
    manifest_rel =
      case RestManifest.resource(manifest, resource) do
        %Manifest.Resource{} = res -> Manifest.Resource.get_relationship(res, rel.name)
        nil -> nil
      end

    if Custom.relationship_pagination(manifest_rel) == :none do
      nil
    else
      ash_pagination(rel.destination, Custom.relationship_read_action(manifest_rel))
    end
  end

  defp ash_pagination(_dest, nil), do: nil

  defp ash_pagination(dest, read_action) do
    case Ash.Resource.Info.action(dest, read_action) do
      %{pagination: %Ash.Resource.Actions.Read.Pagination{} = p} ->
        %Manifest.Pagination{
          offset?: p.offset?,
          keyset?: p.keyset?,
          required?: p.required?,
          countable?: p.countable != false,
          default_limit: p.default_limit,
          max_page_size: p.max_page_size
        }

      _ ->
        nil
    end
  end

  defp page_schema(%Manifest.Pagination{} = pagination) do
    limit = %{"type" => "integer", "minimum" => 1, "description" => "Maximum number of records."}

    limit =
      if pagination.max_page_size,
        do: Map.put(limit, "maximum", pagination.max_page_size),
        else: limit

    props = %{"limit" => limit}

    props =
      if pagination.countable?,
        do:
          Map.put(props, "count", %{
            "type" => "boolean",
            "description" => "Return the total `count` of matching records."
          }),
        else: props

    props =
      if pagination.offset?,
        do:
          Map.put(props, "offset", %{
            "type" => "integer",
            "minimum" => 0,
            "description" => "Number of records to skip (offset pagination)."
          }),
        else: props

    props =
      if pagination.keyset?,
        do:
          Map.merge(props, %{
            "after" => %{
              "type" => "string",
              "description" => "Cursor of the last record of the previous page (`next_cursor`)."
            },
            "before" => %{
              "type" => "string",
              "description" => "Cursor of the first record of the next page (`prev_cursor`)."
            }
          }),
        else: props

    %{"type" => "object", "properties" => props, "additionalProperties" => false}
  end

  # `[author: [], comments: [author: []]]` -> `["author", "comments", "comments.author"]`
  defp include_paths(includes, prefix \\ nil) do
    Enum.flat_map(includes, fn {name, nested} ->
      path = if prefix, do: "#{prefix}.#{name}", else: to_string(name)
      [path | include_paths(nested, path)]
    end)
  end

  # A `parameter_descriptions` entry of the route, keyed by the DSL name
  # (path parameter or `query_params` entry).
  defp parameter_description(%Route{parameter_descriptions: descriptions}, name) do
    Enum.find_value(descriptions, fn {key, description} ->
      if to_string(key) == to_string(name), do: description
    end)
  end

  # The route's `query_params`, typed from the action inputs they feed.
  defp query_parameters(
         reg,
         %{route: %Route{query_params: names}, res: res, action: action} = ctx
       )
       when is_list(names) and names != [] do
    inputs = action_inputs(res, action)

    Enum.map_reduce(names, reg, fn name, reg ->
      client = input_client_name(res, action, name)

      case Map.get(inputs, client) do
        %Manifest.Argument{} = input ->
          {schema, reg} = Schema.type(reg, input.type, :input)

          param =
            %{
              "name" => client,
              "in" => "query",
              "required" => input.required? == true,
              "schema" => if(input.allow_nil?, do: Schema.nullable(schema), else: schema)
            }
            |> maybe_put(
              "description",
              parameter_description(ctx.route, name) || input.description
            )

          {param, reg}

        nil ->
          param =
            %{"name" => client, "in" => "query", "schema" => %{"type" => "string"}}
            |> maybe_put("description", parameter_description(ctx.route, name))

          {param, reg}
      end
    end)
  end

  defp query_parameters(reg, _ctx), do: {[], reg}

  # -- request bodies ---------------------------------------------------------

  defp request_body(reg, %{route: %Route{method: method} = route, action: action, res: res} = ctx)
       when method in @write_methods and not is_nil(action) do
    excluded =
      ctx.path_params ++ Enum.map(route.query_params, &input_client_name(res, action, &1))

    inputs =
      res
      |> action_inputs(action)
      |> Enum.reject(fn {client, _input} -> client in excluded end)
      |> Enum.sort_by(fn {client, _} -> client end)

    if inputs == [] do
      {nil, reg}
    else
      {props, reg} = input_properties(reg, inputs)

      required = required_inputs(route, inputs)

      schema =
        %{"type" => "object", "properties" => props, "additionalProperties" => false}
        |> put_required(required)

      body =
        %{
          "required" => required != [],
          "content" => %{@json => %{"schema" => schema}}
        }
        |> maybe_put("description", route.request_body_description)

      {body, reg}
    end
  end

  defp request_body(reg, _ctx), do: {nil, reg}

  # PATCH bodies are partial updates: nothing is required.
  defp required_inputs(%Route{type: :patch}, _inputs), do: []

  defp required_inputs(_route, inputs),
    do: for({client, input} <- inputs, input.required? == true, do: client)

  defp input_properties(reg, inputs) do
    Enum.reduce(inputs, {%{}, reg}, fn {client, input}, {props, reg} ->
      {schema, reg} = Schema.type(reg, input.type, :input)
      schema = if input.allow_nil?, do: Schema.nullable(schema), else: schema
      {Map.put(props, client, maybe_put(schema, "description", input.description)), reg}
    end)
  end

  # `%{"client_name" => %Manifest.Argument{}}` for the action's inputs.
  defp action_inputs(_res, nil), do: %{}

  defp action_inputs(res, %Manifest.Action{inputs: inputs} = action) do
    Map.new(inputs, fn input -> {input_client_name(res, action, input.name), input} end)
  end

  defp input_client_name(res, action, name) do
    reverse =
      case Custom.action_expected_input_keys(action) do
        keys when is_map(keys) -> Map.new(keys, fn {client, internal} -> {internal, client} end)
        _ -> %{}
      end

    Map.get(reverse, name) ||
      (res && Map.get(Custom.field_names(res), name)) ||
      to_string(name)
  end

  # -- responses --------------------------------------------------------------

  defp responses(reg, %{route: route} = ctx) do
    {success, reg} = success_schema(reg, ctx)
    status = if route.type == :post, do: "201", else: "200"

    error_statuses =
      ["400", "403", "500"] ++
        if(ctx.path_params != [] or route.type in [:patch, :delete], do: ["404"], else: []) ++
        if(route.method in @write_methods, do: ["413", "415"], else: [])

    errors =
      Map.new(error_statuses, fn code ->
        {code, %{"$ref" => "#/components/responses/#{Map.fetch!(@error_responses, code)}"}}
      end)

    responses =
      Map.put(errors, status, %{
        "description" => route.response_description || success_description(route),
        "content" => %{@json => %{"schema" => success}}
      })

    {responses, reg}
  end

  defp success_description(%Route{type: :index}), do: "The matching records."
  defp success_description(%Route{type: :post}), do: "The created record."
  defp success_description(%Route{type: :patch}), do: "The updated record."
  defp success_description(%Route{type: :delete}), do: "The deleted record."
  defp success_description(%Route{type: :related}), do: "The related records."
  defp success_description(%Route{type: :route}), do: "The action result."
  defp success_description(_route), do: "The record."

  defp success_schema(reg, %{route: %Route{type: type}, resource: resource, action: action})
       when type in [:get, :post, :patch, :delete] do
    record_schema(reg, resource, action)
  end

  defp success_schema(reg, %{route: %Route{type: :index}} = ctx), do: list_schema(reg, ctx)

  defp success_schema(reg, %{route: %Route{type: :related}, kind: :list} = ctx),
    do: list_schema(reg, ctx)

  defp success_schema(reg, %{route: %Route{type: :related}, kind: :record} = ctx) do
    {schema, reg} = Schema.resource(reg, ctx.list.target)
    {Schema.nullable(schema), reg}
  end

  defp success_schema(reg, %{route: %Route{type: :route} = route, action: action} = ctx) do
    case action do
      %Manifest.Action{type: :action, returns: nil} ->
        {%{
           "type" => "object",
           "description" => "The action completed without a return value.",
           "required" => ["success"],
           "properties" => %{"success" => %{"const" => true}}
         }, reg}

      %Manifest.Action{type: :action, returns: returns} ->
        {schema, reg} = Schema.type(reg, returns, :output)
        schema = if returns.allow_nil?, do: Schema.nullable(schema), else: schema

        if route.wrap_in_result? do
          {%{"type" => "object", "required" => ["result"], "properties" => %{"result" => schema}},
           reg}
        else
          {schema, reg}
        end

      %Manifest.Action{type: :read, get?: get?} when get? != true ->
        list_schema(reg, ctx)

      _ ->
        record_schema(reg, ctx.resource, action)
    end
  end

  # A page wrapper when the route can answer with a page, the data-only
  # wrapper otherwise.
  defp list_schema(reg, %{list: %{target: target, pagination: pagination}}) do
    Schema.list(reg, target, paginated?: not is_nil(pagination))
  end

  # A record, plus its action metadata under `meta` when the action declares any.
  defp record_schema(reg, resource, action) do
    {record, reg} = Schema.resource(reg, resource)

    case action do
      %Manifest.Action{metadata: [_ | _] = metadata} ->
        {props, reg} = metadata_properties(reg, metadata)

        {%{
           "allOf" => [
             record,
             %{
               "type" => "object",
               "properties" => %{
                 "meta" => %{
                   "type" => "object",
                   "description" => "Metadata of the action, when non-empty.",
                   "properties" => props
                 }
               }
             }
           ]
         }, reg}

      _ ->
        {record, reg}
    end
  end

  defp metadata_properties(reg, metadata) do
    Enum.reduce(metadata, {%{}, reg}, fn meta, {props, reg} ->
      {schema, reg} = Schema.type(reg, meta.type, :output)
      schema = if meta.allow_nil? == false, do: schema, else: Schema.nullable(schema)
      schema = maybe_put(schema, "description", meta.description)
      {Map.put(props, to_string(meta.name), schema), reg}
    end)
  end

  # -- errors -----------------------------------------------------------------

  # Mirrors `AshRest.Errors`: `status`, `code` and `message` always; `details`
  # (one entry per underlying error) only when there is more than one error or
  # the error names a field; `field` is omitted or `null` when there is none.
  defp error_schemas do
    %{
      "Error" => %{
        "type" => "object",
        "description" => "An error response.",
        "required" => ["error"],
        "properties" => %{
          "error" => %{
            "type" => "object",
            "required" => ["status", "code", "message"],
            "properties" => %{
              "status" => %{"type" => "integer", "description" => "The HTTP status code."},
              "code" => %{"type" => "string", "description" => "A machine-readable error code."},
              "message" => %{"type" => "string", "description" => "A human-readable message."},
              "details" => %{
                "type" => "array",
                "description" => "One entry per underlying error.",
                "items" => Schema.ref("ErrorDetail")
              }
            }
          }
        }
      },
      "ErrorDetail" => %{
        "type" => "object",
        "required" => ["code", "message"],
        "properties" => %{
          "field" => %{
            "type" => ["string", "null"],
            "description" =>
              "The input field or query parameter the error refers to, as a dotted path " <>
                "(e.g. `title`, `filter.score.eq`, `page.limit`). Absent or `null` when " <>
                "the error is not about a field."
          },
          "code" => %{"type" => "string", "description" => "A machine-readable error code."},
          "message" => %{"type" => "string", "description" => "A human-readable message."}
        }
      }
    }
  end

  defp error_response_components do
    descriptions = %{
      "BadRequest" =>
        "The request is invalid (bad input, unknown field, bad query parameter, " <>
          "or a body that is not a JSON object).",
      "Forbidden" => "The actor is not allowed to perform this action.",
      "NotFound" => "No record matches the given identifier.",
      "PayloadTooLarge" => "The request body exceeds the size limit.",
      "UnsupportedMediaType" => "The request body is not `application/json`.",
      "InternalServerError" => "An unexpected error occurred."
    }

    Map.new(descriptions, fn {name, description} ->
      {name,
       %{
         "description" => description,
         "content" => %{@json => %{"schema" => Schema.ref("Error")}}
       }}
    end)
  end

  defp put_required(schema, []), do: schema
  defp put_required(schema, required), do: Map.put(schema, "required", required)

  defp maybe_put(map, _key, nil), do: map
  defp maybe_put(map, key, value), do: Map.put(map, key, value)
end
