# SPDX-FileCopyrightText: 2026 ash_rest contributors
#
# SPDX-License-Identifier: MIT

defmodule AshRest.Test do
  @moduledoc """
  Request and assertion helpers for testing an `AshRest.Router`.

  The helpers are built on `Plug.Test` and call the router directly, so they need
  neither Phoenix nor a running endpoint.

      defmodule MyApp.PostApiTest do
        use ExUnit.Case, async: true

        import AshRest.Test

        alias MyApp.Rest.Router

        test "creates and reads a post" do
          conn = post(Router, "/posts", %{title: "Hello"})
          %{"id" => id} = assert_record(conn, %{"type" => "post", "title" => "Hello"})

          Router
          |> get("/posts/\#{id}")
          |> assert_record(%{"id" => ^id})
        end

        test "validates input" do
          Router
          |> post("/posts", %{}, status: 400)
          |> assert_error_detail("title", "required")
        end
      end

  ## Requests

  `get/3`, `post/4`, `put/4`, `patch/4` and `delete/3` send a request through
  the router and assert that

    * the response has the expected status (`:status`, default `200`, `201` for `post/4`),
    * the response content type is `application/json`.

  They return the `Plug.Conn`, with the decoded JSON body in `conn.assigns.json`
  (also available as `json/1`). Every assertion helper takes that conn, so
  requests and assertions pipe together.

  Options:

    * `:status` - the expected response status.
    * `:actor` - the actor, set with `Ash.PlugHelpers.set_actor/2`.
    * `:tenant` - the tenant, set with `Ash.PlugHelpers.set_tenant/2`.
    * `:headers` - extra request headers, as a list of `{name, value}`.
    * `:query` - a map or keyword list encoded as the query string and appended
      to `path`, e.g. `query: [filter: [title: "Hello"], page: [limit: 10]]`.
    * `:content_type` - the request content type. Defaults to `"application/json"`
      when a body is sent.
    * `:raw_body` - a string sent as the body as is, instead of encoding `body`.
    * `:openapi` - validate the response against an OpenAPI document with
      `Oaskit.Test.valid_response/3`: a spec module, `true` for the router's own
      `<Router>.OpenApi` module, or `false`. Defaults to the value set with
      `validate_openapi/1`, else `false`. Requires `oaskit`.

  ## OpenAPI validation

  With [`oaskit`](https://hexdocs.pm/oaskit) installed, `use AshRest.Router`
  defines a `<Router>.OpenApi` spec module. To check every response of your test
  suite against the generated document, call `validate_openapi/1` once in
  `test/test_helper.exs`:

      ExUnit.start()
      AshRest.Test.validate_openapi(true)

  Responses that were not served by a route (the `no_route_found` 404) have no
  OpenAPI operation and are not validated.
  """

  import ExUnit.Assertions

  @oaskit? Code.ensure_loaded?(Oaskit)
  @openapi_key {__MODULE__, :openapi}
  @list_keys ~w(data has_more count limit offset next_cursor prev_cursor meta)

  @type option ::
          {:status, pos_integer()}
          | {:actor, term()}
          | {:tenant, term()}
          | {:headers, [{String.t(), String.t()}]}
          | {:query, map() | keyword()}
          | {:content_type, String.t()}
          | {:raw_body, String.t()}
          | {:openapi, module() | boolean()}

  # -- requests ----------------------------------------------------------------

  @doc "Sends `GET path` through `router`. See the module docs for the options."
  @spec get(module(), String.t(), [option()]) :: Plug.Conn.t()
  def get(router, path, opts \\ []), do: request(router, :get, path, nil, opts, 200)

  @doc """
  Sends `POST path` with `body` encoded as JSON. Expects `201` unless `:status`
  is given (generic routes answer `200`). See the module docs for the options.
  """
  @spec post(module(), String.t(), term(), [option()]) :: Plug.Conn.t()
  def post(router, path, body, opts \\ []), do: request(router, :post, path, body, opts, 201)

  @doc "Sends `PUT path` with `body` encoded as JSON. See the module docs for the options."
  @spec put(module(), String.t(), term(), [option()]) :: Plug.Conn.t()
  def put(router, path, body, opts \\ []), do: request(router, :put, path, body, opts, 200)

  @doc "Sends `PATCH path` with `body` encoded as JSON. See the module docs for the options."
  @spec patch(module(), String.t(), term(), [option()]) :: Plug.Conn.t()
  def patch(router, path, body, opts \\ []), do: request(router, :patch, path, body, opts, 200)

  @doc "Sends `DELETE path`. See the module docs for the options."
  @spec delete(module(), String.t(), [option()]) :: Plug.Conn.t()
  def delete(router, path, opts \\ []), do: request(router, :delete, path, nil, opts, 200)

  @doc """
  Sets the default of the `:openapi` request option for every test.

  Pass `true` to validate each response against the router's own `<Router>.OpenApi`
  module, a spec module to always use that one, or `false` to turn validation off.
  Call it in `test/test_helper.exs`.
  """
  @spec validate_openapi(module() | boolean()) :: :ok
  def validate_openapi(spec) when is_atom(spec) do
    if spec, do: ensure_oaskit!()
    :persistent_term.put(@openapi_key, spec)
    :ok
  end

  @doc """
  The decoded JSON body of a response.

  Returns `conn.assigns.json` for conns returned by the request helpers, and
  decodes `conn.resp_body` otherwise (e.g. for a conn from `Phoenix.ConnTest`).
  """
  @spec json(Plug.Conn.t()) :: term()
  def json(%Plug.Conn{assigns: %{json: json}}), do: json

  def json(%Plug.Conn{state: state, resp_body: body}) when state in [:sent, :set] do
    case body do
      "" -> nil
      body -> Jason.decode!(body)
    end
  end

  def json(%Plug.Conn{}), do: flunk("Expected a response, but no response was sent")

  defp request(router, method, path, body, opts, default_status) do
    status = Keyword.get(opts, :status, default_status)
    {raw_body, content_type} = request_body(body, opts)

    conn =
      method
      |> Plug.Test.conn(with_query(path, opts[:query]), raw_body)
      |> put_headers(opts[:headers] || [])
      |> maybe_put_content_type(content_type)
      |> maybe_set(:actor, opts)
      |> maybe_set(:tenant, opts)
      |> router.call(router.init([]))

    assert conn.state == :sent,
           "Expected #{inspect(router)} to send a response to #{method_name(method)} #{path}"

    assert conn.status == status, """
    Expected #{method_name(method)} #{path} to respond with status #{status}, got #{conn.status}.

    Response body:
    #{pretty_body(conn.resp_body)}
    """

    assert_json_content_type(conn, method, path)

    conn = Plug.Conn.assign(conn, :json, decode!(conn, method, path))

    case Keyword.get_lazy(opts, :openapi, &default_openapi/0) do
      false -> conn
      nil -> conn
      true -> validate_response(conn, Module.concat(router, OpenApi), status)
      spec -> validate_response(conn, spec, status)
    end
  end

  defp request_body(body, opts) do
    case Keyword.fetch(opts, :raw_body) do
      {:ok, raw} when is_binary(raw) ->
        {raw, Keyword.get(opts, :content_type, "application/json")}

      :error when is_nil(body) ->
        {"", opts[:content_type]}

      :error ->
        {Jason.encode!(body), Keyword.get(opts, :content_type, "application/json")}
    end
  end

  defp with_query(path, nil), do: path
  defp with_query(path, query) when query == %{} or query == [], do: path

  defp with_query(path, query) do
    separator = if String.contains?(path, "?"), do: "&", else: "?"
    path <> separator <> Plug.Conn.Query.encode(query)
  end

  defp put_headers(conn, headers) do
    Enum.reduce(headers, conn, fn {name, value}, conn ->
      Plug.Conn.put_req_header(conn, String.downcase(to_string(name)), to_string(value))
    end)
  end

  defp maybe_put_content_type(conn, nil), do: conn

  defp maybe_put_content_type(conn, content_type),
    do: Plug.Conn.put_req_header(conn, "content-type", content_type)

  defp maybe_set(conn, :actor, opts) do
    case Keyword.fetch(opts, :actor) do
      {:ok, actor} -> Ash.PlugHelpers.set_actor(conn, actor)
      :error -> conn
    end
  end

  defp maybe_set(conn, :tenant, opts) do
    case Keyword.fetch(opts, :tenant) do
      {:ok, tenant} -> Ash.PlugHelpers.set_tenant(conn, tenant)
      :error -> conn
    end
  end

  defp assert_json_content_type(conn, method, path) do
    content_type = conn |> Plug.Conn.get_resp_header("content-type") |> List.first()

    assert is_binary(content_type) and String.starts_with?(content_type, "application/json"),
           "Expected #{method_name(method)} #{path} to respond with application/json, " <>
             "got content type #{inspect(content_type)}"
  end

  defp decode!(conn, method, path) do
    case conn.resp_body do
      "" ->
        nil

      body ->
        case Jason.decode(body) do
          {:ok, json} ->
            json

          {:error, _} ->
            flunk("Expected #{method_name(method)} #{path} to respond with JSON, got:\n#{body}")
        end
    end
  end

  defp default_openapi, do: :persistent_term.get(@openapi_key, false)

  defp validate_response(conn, spec, status) do
    case conn.private do
      %{oaskit: %{operation_id: operation_id}} when is_binary(operation_id) ->
        valid_response!(spec, conn, status)

      _ ->
        # Not served by a route (e.g. no_route_found): no operation to validate against.
        conn
    end
  end

  if @oaskit? do
    defp valid_response!(spec, conn, status) do
      Oaskit.Test.valid_response(spec, conn, status)
      conn
    end

    defp ensure_oaskit!, do: :ok
  else
    defp valid_response!(_spec, _conn, _status), do: ensure_oaskit!()

    defp ensure_oaskit! do
      raise ArgumentError,
            "OpenAPI validation needs the optional `oaskit` dependency, add {:oaskit, \"~> 0.18\"} to your deps"
    end
  end

  defp method_name(method), do: method |> to_string() |> String.upcase()

  defp pretty_body(body) do
    case Jason.decode(body) do
      {:ok, json} -> Jason.encode!(json, pretty: true)
      {:error, _} -> body
    end
  end

  # -- assertions --------------------------------------------------------------

  @doc """
  Asserts that the response body is a single record (a JSON object) and returns it.

  `expected` is either

    * a map *pattern* written inline, matched with `=`: keys are strings, unlisted
      keys are ignored, `^pinned` values and bound variables work as in a `case`
      clause (`%{"id" => id} = ...` binds `id` in the test), or
    * any other expression evaluating to a map, compared as a subset after a JSON
      round trip (so atom keys and values such as dates may be used).

  Examples:

      assert_record(conn, %{"type" => "post", "title" => "Hello"})
      %{"id" => id} = assert_record(conn, %{"author_id" => ^author_id})

      expected = %{title: "Hello", status: :draft}
      assert_record(conn, expected)
  """
  defmacro assert_record(conn, expected) do
    if map_pattern?(expected) do
      quote do
        record = AshRest.Test.__record__(unquote(conn))
        ExUnit.Assertions.assert(unquote(expected) = record)
        record
      end
    else
      quote do
        AshRest.Test.__assert_subset__(
          AshRest.Test.__record__(unquote(conn)),
          unquote(expected)
        )
      end
    end
  end

  @doc """
  Asserts that the response body is a list wrapper (`{"data": [...]}`) and
  returns the records in `"data"`.

  `expected` is

    * an integer: the number of records,
    * a list *pattern* written inline, matched against `"data"` with `=` (order
      and length matter, see `assert_record/2` for pattern semantics),
    * a map *pattern* written inline, matched against the whole wrapper, e.g.
      `%{"has_more" => true, "count" => 3}`,
    * any other expression: a list of maps compared element by element as subsets,
      or a map compared as a subset of the wrapper.

  Examples:

      assert_list(conn, 2)
      assert_list(conn, [%{"title" => "A"}, %{"title" => "B"}])
      assert_list(conn, %{"has_more" => false, "data" => [_]})
  """
  defmacro assert_list(conn, expected) do
    cond do
      list_pattern?(expected) ->
        quote do
          records = AshRest.Test.__records__(unquote(conn))
          ExUnit.Assertions.assert(unquote(expected) = records)
          records
        end

      map_pattern?(expected) ->
        quote do
          conn = unquote(conn)
          records = AshRest.Test.__records__(conn)
          ExUnit.Assertions.assert(unquote(expected) = AshRest.Test.json(conn))
          records
        end

      true ->
        quote do
          AshRest.Test.__assert_list__(unquote(conn), unquote(expected))
        end
    end
  end

  @doc """
  Asserts that the response is an error envelope with the given HTTP `status`
  and error `code`, and returns the error object (the value of `"error"`).

      assert_error(conn, 404, "not_found")
  """
  @spec assert_error(Plug.Conn.t(), pos_integer(), String.t()) :: map()
  def assert_error(%Plug.Conn{} = conn, status, code) do
    error = error!(conn)

    assert conn.status == status,
           "Expected status #{status}, got #{conn.status}:\n#{inspect(error, pretty: true)}"

    assert error["status"] == status,
           "Expected the error status to be #{status}:\n#{inspect(error, pretty: true)}"

    assert error["code"] == code,
           "Expected error code #{inspect(code)}, got #{inspect(error["code"])}:\n" <>
             inspect(error, pretty: true)

    error
  end

  @doc """
  Asserts that the error envelope has an entry in `"details"` for `field` with
  `code`, and returns that entry.

  `field` is the dotted path reported in `details[].field`, e.g. `"title"`,
  `"filter.score.eq"` or `"page.limit"`.

      assert_error_detail(conn, "title", "required")
  """
  @spec assert_error_detail(Plug.Conn.t(), String.t() | nil, String.t()) :: map()
  def assert_error_detail(%Plug.Conn{} = conn, field, code) do
    error = error!(conn)
    details = error["details"] || []

    case Enum.find(details, &(&1["field"] == field and &1["code"] == code)) do
      nil ->
        flunk(
          "Expected an error detail with field #{inspect(field)} and code #{inspect(code)}, got:\n" <>
            inspect(error, pretty: true)
        )

      detail ->
        detail
    end
  end

  @doc false
  def __record__(%Plug.Conn{} = conn) do
    case json(conn) do
      %{"error" => %{"code" => _}} = body ->
        flunk("Expected a record, got an error:\n#{inspect(body, pretty: true)}")

      %{"data" => records} = body when is_list(records) and map_size(body) <= 8 ->
        if Map.keys(body) -- @list_keys == [] do
          flunk("Expected a record, got a list:\n#{inspect(body, pretty: true)}")
        else
          body
        end

      %{} = record ->
        record

      other ->
        flunk("Expected a record (a JSON object), got:\n#{inspect(other, pretty: true)}")
    end
  end

  @doc false
  def __records__(%Plug.Conn{} = conn) do
    case json(conn) do
      %{"data" => records} when is_list(records) ->
        records

      other ->
        flunk(
          "Expected a list response ({\"data\": [...]}), got:\n#{inspect(other, pretty: true)}"
        )
    end
  end

  @doc false
  def __assert_list__(conn, count) when is_integer(count) do
    records = __records__(conn)

    assert length(records) == count,
           "Expected #{count} records, got #{length(records)}:\n#{inspect(records, pretty: true)}"

    records
  end

  def __assert_list__(conn, expected) when is_list(expected) do
    records = __records__(conn)

    assert length(records) == length(expected),
           "Expected #{length(expected)} records, got #{length(records)}:\n" <>
             inspect(records, pretty: true)

    records
    |> Enum.zip(expected)
    |> Enum.each(fn {record, expected} -> __assert_subset__(record, expected) end)

    records
  end

  def __assert_list__(conn, %{} = expected) do
    records = __records__(conn)
    __assert_subset__(json(conn), expected)
    records
  end

  @doc false
  def __assert_subset__(actual, %{} = expected) do
    expected = expected |> Jason.encode!() |> Jason.decode!()

    mismatched =
      Enum.reject(expected, fn {key, value} -> Map.fetch(actual, key) == {:ok, value} end)

    assert mismatched == [], """
    Expected the response to contain:
    #{inspect(Map.new(mismatched), pretty: true)}

    Got:
    #{inspect(Map.take(actual, Enum.map(mismatched, &elem(&1, 0))), pretty: true)}

    Full body:
    #{inspect(actual, pretty: true)}
    """

    actual
  end

  def __assert_subset__(_actual, expected) do
    raise ArgumentError, "expected a map to compare the record with, got: #{inspect(expected)}"
  end

  defp error!(conn) do
    case json(conn) do
      %{"error" => %{} = error} -> error
      other -> flunk("Expected an error response, got:\n#{inspect(other, pretty: true)}")
    end
  end

  defp map_pattern?({:%{}, _, _}), do: true
  defp map_pattern?({:=, _, [left, right]}), do: map_pattern?(left) or map_pattern?(right)
  defp map_pattern?(_), do: false

  defp list_pattern?(list) when is_list(list), do: true
  defp list_pattern?({:=, _, [left, right]}), do: list_pattern?(left) or list_pattern?(right)
  defp list_pattern?(_), do: false
end
