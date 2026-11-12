# SPDX-FileCopyrightText: 2026 ash_rest contributors
#
# SPDX-License-Identifier: MIT

defmodule AshRest.Controller do
  @moduledoc """
  Serves one routed request: HTTP in, ash_rpc params, ash_rpc out, HTTP response.

  `AshRest.Router` calls `call/2` once it has matched a route and parsed a JSON
  body. The controller

  1. rejects write requests whose content type is not `application/json`, or
     that send a body without a content type (415),
  2. parses the query string with `AshRest.Params`,
  3. builds the ash_rpc params for the route type, with the default field
     selection from `AshRest.Fields`,
  4. runs `AshRpc.run_action/3` with the conn (actor and tenant come from
     `Ash.PlugHelpers`),
  5. renders the result with `AshRest.Response` or `AshRest.Errors`, applying the
     route's `metadata` and `modify_conn` functions.

  Every routed request gets `conn.private.oaskit.operation_id` set to the route
  name (by the router, before the body is parsed), so `Oaskit.Test.valid_response/3`
  can validate responses against the generated OpenAPI document.

  ## Route `metadata` and `modify_conn`

  `metadata` is called as `metadata.(subject, result, request)` and `modify_conn`
  as `modify_conn.(conn, subject, result, request)`, where `subject` is a map
  with `:actor`, `:tenant`, `:resource` and `:action`, `result` is the rendered
  data (the record, the list of records, or the raw value) and `request` is the
  `Plug.Conn`.
  """

  import Plug.Conn

  alias AshRest.{Errors, Fields, Params, Response}
  alias AshRest.Resource.Info
  alias AshRpc.Manifest.Custom

  @type ctx :: %{
          router: module(),
          domain: module(),
          resource: module(),
          route: AshRest.Resource.Route.t(),
          path_params: %{String.t() => String.t()}
        }

  @write_methods ~w(POST PATCH PUT)

  @doc "Handles a matched route. See the module documentation."
  @spec call(Plug.Conn.t(), ctx()) :: Plug.Conn.t()
  def call(conn, %{router: router, resource: resource, route: route} = ctx) do
    conn = put_private(conn, :oaskit, %{operation_id: route.name})
    manifest = AshRest.Manifest.get(router)
    action = AshRest.Manifest.action(manifest, resource, route.action)
    entrypoint = AshRpc.Manifest.entrypoint_lookup(manifest)[route.name]
    kind = kind(route, action, manifest)

    with {:ok, conn, body} <- body(conn),
         {:ok, params} <- parse_params(conn, route, resource, kind, manifest),
         {:ok, params} <- related_params(conn, route, resource, params) do
      {rpc_params, render} =
        build(route, %{
          resource: resource,
          manifest: manifest,
          action: action,
          entrypoint: entrypoint,
          kind: kind,
          params: params,
          body: body,
          path_params: ctx.path_params
        })

      router
      |> AshRpc.run_action(conn, rpc_params)
      |> respond(conn, ctx, render)
    else
      {:error, %Plug.Conn{} = conn} -> conn
    end
  end

  # -- request ---------------------------------------------------------------

  # A write request's body must be `application/json` (parsed by the router, or
  # by an upstream `Plug.Parsers`) or empty. The content type is checked, not
  # only whether `body_params` was parsed: an upstream parser accepting form
  # bodies leaves a parsed map behind, and a body without a content type is
  # skipped by `Plug.Parsers` and would otherwise pass as "no input".
  defp body(%Plug.Conn{method: method} = conn) when method in @write_methods do
    case content_type(conn) do
      :json -> json_body(conn)
      :none -> body_without_content_type(conn)
      :other -> unsupported_media_type(conn)
    end
  end

  defp body(conn), do: {:ok, conn, %{}}

  defp json_body(%Plug.Conn{body_params: %Plug.Conn.Unfetched{}} = conn), do: {:ok, conn, %{}}

  defp json_body(%Plug.Conn{body_params: %{"_json" => _}} = conn) do
    {:error,
     Errors.send_error(conn, 400, "invalid_body", "The request body must be a JSON object")}
  end

  defp json_body(%Plug.Conn{body_params: body} = conn) when is_map(body), do: {:ok, conn, body}

  defp body_without_content_type(conn) do
    case read_body(conn) do
      {:ok, "", conn} -> {:ok, conn, %{}}
      {_, _body, conn} -> unsupported_media_type(conn)
    end
  end

  defp unsupported_media_type(conn) do
    {:error,
     Errors.send_error(
       conn,
       415,
       "unsupported_media_type",
       "Request bodies must be sent as application/json"
     )}
  end

  # :json for application/json and application/*+json, :none without a header.
  defp content_type(conn) do
    case get_req_header(conn, "content-type") do
      [] ->
        :none

      [value | _] ->
        case Plug.Conn.Utils.content_type(value) do
          {:ok, "application", "json", _params} ->
            :json

          {:ok, "application", subtype, _params}
          when binary_part(subtype, byte_size(subtype) - 5, 5) == "+json" ->
            :json

          _ ->
            :other
        end
    end
  end

  defp parse_params(conn, route, resource, kind, manifest) do
    {include_resource, includes} = include_scope(route, resource)

    opts = [
      kind: kind,
      paginate?: route.paginate?,
      includes: includes,
      include_names: Info.field_names(include_resource),
      query_params: query_param_names(route, resource, manifest)
    ]

    case Params.parse(conn.query_params, opts) do
      {:ok, params} ->
        {:ok, params}

      {:error, {code, message, details}} ->
        {:error, Errors.send_error(conn, 400, code, message, details: details)}
    end
  end

  # A to-many `related` route runs through the parent's `get` entrypoint, so the
  # route's `enable_filter?`/`enable_sort?` and the relationship's pagination
  # are checked here, with the errors `index` routes get from ash_rpc.
  defp related_params(conn, %{type: :related, relationship: rel} = route, resource, params) do
    relationship = Ash.Resource.Info.relationship(resource, rel)

    cond do
      params.filter != nil and not route.enable_filter? ->
        {:error,
         Errors.send_error(
           conn,
           400,
           "filter_not_supported",
           "This route does not support the filter parameter"
         )}

      params.sort != nil and not route.enable_sort? ->
        {:error,
         Errors.send_error(
           conn,
           400,
           "sort_not_supported",
           "This route does not support the sort parameter"
         )}

      params.page != nil and relationship.cardinality == :many ->
        case related_page(params.page, relationship) do
          {:ok, page} ->
            {:ok, %{params | page: page}}

          {:error, {code, message, details}} ->
            {:error, Errors.send_error(conn, 400, code, message, details: details)}
        end

      true ->
        {:ok, params}
    end
  end

  defp related_params(_conn, _route, _resource, params), do: {:ok, params}

  # Ash paginates a relationship load only when the page has a `limit`, so one
  # is taken from the relationship's read action (`default_limit`, else
  # `max_page_size`, as Ash does for runtime pagination) when the client sends
  # none. Cursors need a keyset-capable read action.
  defp related_page(page, relationship) do
    pagination =
      case Ash.Resource.Info.action(
             relationship.destination,
             relationship.read_action ||
               Ash.Resource.Info.primary_action!(relationship.destination, :read).name
           ) do
        %{pagination: %{} = pagination} -> pagination
        _ -> nil
      end

    cursor? = Map.has_key?(page, "after") or Map.has_key?(page, "before")

    cond do
      is_nil(pagination) ->
        {:error,
         {"pagination_not_supported", "This route does not support the page parameter", []}}

      cursor? and not pagination.keyset? ->
        key = if Map.has_key?(page, "after"), do: "after", else: "before"

        {:error,
         {"invalid_pagination", "page[#{key}] is not supported by this route",
          [
            %{
              "field" => "page.#{key}",
              "code" => "invalid_pagination",
              "message" => "is not supported by this route"
            }
          ]}}

      Map.has_key?(page, "limit") ->
        {:ok, page}

      limit = pagination.default_limit || pagination.max_page_size ->
        {:ok, Map.put(page, "limit", limit)}

      true ->
        {:error,
         {"invalid_pagination", "page[limit] is required to paginate this route",
          [
            %{
              "field" => "page.limit",
              "code" => "invalid_pagination",
              "message" => "is required to paginate this route"
            }
          ]}}
    end
  end

  # The include allow-list: the resource's tree, or the subtree under the
  # relationship for `related` routes (whose records are the destination's).
  defp include_scope(%{type: :related, relationship: rel}, resource) do
    dest = Ash.Resource.Info.relationship(resource, rel).destination
    {dest, Keyword.get(Info.includes(resource), rel, [])}
  end

  defp include_scope(_route, resource), do: {resource, Info.includes(resource)}

  # `%{wire_name => wire_name}` of the route's query_params (argument renames apply).
  defp query_param_names(%{query_params: []}, _resource, _manifest), do: %{}

  defp query_param_names(route, resource, manifest) do
    res = AshRest.Manifest.resource(manifest, resource)

    Map.new(route.query_params, fn name ->
      wire =
        Custom.argument_name_override(res, route.action, name) ||
          to_string(name)

      {wire, wire}
    end)
  end

  # :list routes take filter/sort/page/include, :record routes take include,
  # :value routes take neither.
  defp kind(%{type: :index}, _action, _manifest), do: :list

  defp kind(%{type: type}, _action, _manifest) when type in [:get, :post, :patch, :delete],
    do: :record

  defp kind(%{type: :related, relationship: rel, resource: resource}, _action, _manifest) do
    case Ash.Resource.Info.relationship(resource, rel).cardinality do
      :many -> :list
      :one -> :record
    end
  end

  defp kind(%{type: :route}, %{type: :read, get?: true}, _manifest), do: :record
  defp kind(%{type: :route}, %{type: :read}, _manifest), do: :list

  defp kind(%{type: :route}, %{type: type}, _manifest) when type in [:create, :update, :destroy],
    do: :record

  defp kind(%{type: :route}, action, manifest) do
    if Fields.resource_module(manifest, action.returns), do: :record, else: :value
  end

  # -- ash_rpc params --------------------------------------------------------

  defp build(%{type: :get} = route, %{params: params} = b) do
    {fields, shape} = Fields.selection(b.manifest, b.resource, params.include)

    {%{action: route.name, get_by: get_by(b), input: params.input, fields: fields},
     {:record, shape, 200}}
  end

  defp build(%{type: :index} = route, %{params: params} = b) do
    {fields, shape} = Fields.selection(b.manifest, b.resource, params.include)

    {compact(%{
       action: route.name,
       fields: fields,
       input: params.input,
       filter: params.filter,
       sort: params.sort,
       page: params.page
     }), {:list, shape}}
  end

  defp build(%{type: :post} = route, %{params: params} = b) do
    {fields, shape} = Fields.selection(b.manifest, b.resource, params.include)

    {%{action: route.name, input: Map.merge(b.body, params.input), fields: fields},
     {:record, shape, 201}}
  end

  defp build(%{type: type} = route, %{params: params} = b) when type in [:patch, :delete] do
    {fields, shape} = Fields.selection(b.manifest, b.resource, params.include)

    {%{
       action: route.name,
       identity: b.path_params["id"],
       input: Map.merge(b.body, params.input),
       fields: fields
     }, {:record, shape, 200}}
  end

  defp build(%{type: :related} = route, %{params: params} = b) do
    {fields, rel_name, cardinality, shape} =
      Fields.related_selection(b.manifest, b.resource, route.relationship, params.include, %{
        filter: params.filter,
        sort: params.sort,
        page: params.page
      })

    {%{action: route.name, get_by: get_by(b), input: params.input, fields: fields},
     {:related, rel_name, cardinality, shape}}
  end

  # A generic route to a read action: a list like `index`, or one record (or
  # 404) when the action is `get?`.
  defp build(%{type: :route} = route, %{action: %{type: :read} = action, params: params} = b) do
    {fields, shape} = Fields.selection(b.manifest, b.resource, params.include)
    input = Map.merge(b.path_params, params.input)

    if action.get? do
      {%{action: route.name, fields: fields, input: input}, {:record, shape, 200}}
    else
      {compact(%{
         action: route.name,
         fields: fields,
         input: input,
         filter: params.filter,
         sort: params.sort,
         page: params.page
       }), {:list, shape}}
    end
  end

  # A generic route: the body, the path params (except an `id` used as the
  # identity) and the route's query_params are the action input.
  defp build(%{type: :route} = route, %{params: params, action: action} = b) do
    identity? = b.entrypoint.identities != [] and Map.has_key?(b.path_params, "id")
    path_input = if identity?, do: Map.delete(b.path_params, "id"), else: b.path_params
    input = b.body |> Map.merge(path_input) |> Map.merge(params.input)

    {fields, shape} =
      if action.type == :action,
        do: Fields.return_selection(b.manifest, action, params.include),
        else: Fields.selection(b.manifest, b.resource, params.include)

    rpc_params =
      compact(%{
        action: route.name,
        input: input,
        identity: if(identity?, do: b.path_params["id"]),
        fields: fields
      })

    render =
      cond do
        b.kind == :record -> {:record, shape, 200}
        is_nil(action.returns) -> :void
        true -> :value
      end

    {rpc_params, render}
  end

  defp get_by(%{manifest: manifest, resource: resource, path_params: path_params}) do
    pk = Info.primary_key(resource)
    %{AshRest.Manifest.client_name(manifest, resource, pk) => path_params["id"]}
  end

  defp compact(map), do: Map.reject(map, fn {_key, value} -> is_nil(value) end)

  # -- response --------------------------------------------------------------

  # Errors raised inside a `related` route's relationship envelope carry the
  # relationship as the first path segment; the client sent `filter`/`sort`/
  # `page` directly, so that segment is stripped.
  defp respond(%{"success" => false, "errors" => errors}, conn, _ctx, {:related, rel, _, _}),
    do: Errors.send_rpc_errors(conn, errors, strip_path: [rel])

  defp respond(%{"success" => false, "errors" => errors}, conn, _ctx, _render),
    do: Errors.send_rpc_errors(conn, errors)

  defp respond(%{"success" => true} = result, conn, ctx, render) do
    data = result["data"]
    action_meta = result["metadata"] || %{}

    {status, rendered, body} =
      case render do
        {:record, shape, status} ->
          record = Response.record(data, shape)

          {status, record,
           Response.record(record, nil, merge_meta(action_meta, route_meta(ctx, conn, record)))}

        {:list, shape} ->
          records = Response.typed(data, shape)

          {200, unwrap_results(records),
           Response.list(records, nil, route_meta(ctx, conn, records))}

        {:related, rel_name, :many, shape} ->
          records = Response.typed(data[rel_name] || [], shape)

          {200, unwrap_results(records),
           Response.list(records, nil, route_meta(ctx, conn, records))}

        {:related, rel_name, :one, shape} ->
          record = Response.record(data[rel_name], shape)
          {200, record, Response.record(record, nil, route_meta(ctx, conn, record))}

        :value ->
          {200, data, Response.value(data, ctx.route.wrap_in_result?, false)}

        :void ->
          {200, nil, Response.value(nil, false, true)}
      end

    conn
    |> modify_conn(ctx, rendered)
    |> Response.send(status, body)
  end

  defp unwrap_results(%{"results" => results}), do: results
  defp unwrap_results(records), do: records

  defp merge_meta(action_meta, route_meta), do: Map.merge(action_meta, route_meta)

  defp route_meta(%{route: %{metadata: nil}}, _conn, _result), do: %{}

  defp route_meta(%{route: %{metadata: fun}} = ctx, conn, result) do
    case fun.(subject(ctx, conn), result, conn) do
      meta when is_map(meta) -> Map.new(meta, fn {key, value} -> {to_string(key), value} end)
      _ -> %{}
    end
  end

  defp modify_conn(conn, %{route: %{modify_conn: nil}}, _result), do: conn

  defp modify_conn(conn, %{route: %{modify_conn: fun}} = ctx, result),
    do: fun.(conn, subject(ctx, conn), result, conn)

  defp subject(%{resource: resource, route: route}, conn) do
    %{
      actor: Ash.PlugHelpers.get_actor(conn),
      tenant: Ash.PlugHelpers.get_tenant(conn),
      resource: resource,
      action: route.action
    }
  end
end
