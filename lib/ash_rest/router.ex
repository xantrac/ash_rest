# SPDX-FileCopyrightText: 2026 ash_rest contributors
#
# SPDX-License-Identifier: MIT

defmodule AshRest.Router do
  @moduledoc """
  A Plug that serves the routes of every `AshRest` resource in the given domains.

      defmodule MyAppWeb.RestRouter do
        use AshRest.Router, domains: [MyApp.Blog]
      end

      # Phoenix router
      forward "/api", MyAppWeb.RestRouter

  The router module is also the `AshRpc.Profile` its requests run through.

  ## Options

    * `:domains` (required) - the Ash domains whose `AshRest` resources are served.
    * `:otp_app` - passed to the manifest generator. Defaults to `:ash_rest`.
    * `:open_api` - path of the OpenAPI document, or `false`. Defaults to
      `"/openapi.json"` when `oaskit` is available.
    * `:docs` - path of a Redoc page for the document, or `false`. Defaults to `"/docs"`
      when `oaskit` is available and `:open_api` is enabled.
    * `:open_api_info` - keyword list merged into the document's `info`
      (`:title`, `:version`, `:description`).
    * `:show_raised_errors?` - show the messages of raised exceptions. Defaults to the
      domain's `rest.show_raised_errors?`, else `false`.
    * `:error_handler` - an `AshRpc.ErrorHandler` module or `{m, f, a}` (called as
      `apply(m, f, [error, context | a])`) applied to every error. Defaults to the
      domain's `rest.error_handler`.

  ## Customizing the OpenAPI document

  Override `c:modify_open_api/1` to change the generated document after it is built,
  e.g. to add servers or security schemes:

      @impl AshRest.Router
      def modify_open_api(spec) do
        put_in(spec, ["components", "securitySchemes"], %{
          "bearer" => %{"type" => "http", "scheme" => "bearer"}
        })
      end
  """

  @doc """
  Receives the generated OpenAPI document (a map with string keys) and returns the
  document to serve. Runs last, after every DSL option has been applied. The default
  returns the document unchanged.
  """
  @callback modify_open_api(spec :: map()) :: map()

  @oaskit? Code.ensure_loaded?(Oaskit)

  defmacro __using__(opts) do
    oaskit? = @oaskit?

    quote bind_quoted: [opts: opts, oaskit?: oaskit?] do
      @behaviour Plug
      @behaviour AshRest.Router
      use AshRpc.Profile

      @ash_rest_domains Keyword.fetch!(opts, :domains)
      @ash_rest_open_api Keyword.get(
                           opts,
                           :open_api,
                           if(oaskit?, do: "/openapi.json", else: false)
                         )
      @ash_rest_opts [
        domains: @ash_rest_domains,
        otp_app: Keyword.get(opts, :otp_app, :ash_rest),
        open_api: @ash_rest_open_api,
        docs:
          Keyword.get(
            opts,
            :docs,
            if(oaskit? and @ash_rest_open_api, do: "/docs", else: false)
          ),
        open_api_info: Keyword.get(opts, :open_api_info, []),
        show_raised_errors?: Keyword.get(opts, :show_raised_errors?),
        error_handler: Keyword.get(opts, :error_handler)
      ]

      @doc false
      def __ash_rest__(key), do: Keyword.fetch!(@ash_rest_opts, key)

      @impl AshRpc.Profile
      def manifest, do: AshRest.Manifest.get(__MODULE__)

      @impl AshRpc.Profile
      def error_handler(domain), do: AshRest.Router.error_handler(__MODULE__, domain)

      @impl AshRpc.Profile
      def show_raised_errors?(domain),
        do: AshRest.Router.show_raised_errors?(__MODULE__, domain)

      if oaskit? and @ash_rest_open_api do
        defmodule OpenApi do
          @moduledoc "The OpenAPI 3.1 document of `#{inspect(__MODULE__)}`, for `oaskit`."
          use Oaskit

          @router __MODULE__ |> Module.split() |> Enum.drop(-1) |> Module.concat()

          @impl Oaskit
          def spec, do: AshRest.OpenApi.spec(@router)
        end
      end

      @impl Plug
      def init(opts), do: opts

      @impl Plug
      def call(conn, _opts), do: AshRest.Router.dispatch(conn, __MODULE__)

      @impl AshRest.Router
      def modify_open_api(spec), do: spec

      defoverridable error_handler: 1, show_raised_errors?: 1, modify_open_api: 1
    end
  end

  @doc false
  def error_handler(router, domain) do
    router.__ash_rest__(:error_handler) || domain_option(domain, :error_handler) ||
      AshRpc.DefaultErrorHandler
  end

  @doc false
  def show_raised_errors?(router, domain) do
    case router.__ash_rest__(:show_raised_errors?) do
      nil -> domain_option(domain, :show_raised_errors?) || false
      value -> value
    end
  end

  defp domain_option(nil, _key), do: nil

  defp domain_option(domain, key) do
    if AshRest.Domain in Spark.extensions(domain) do
      apply(AshRest.Domain.Info, key, [domain])
    end
  rescue
    _ -> nil
  end

  @parsers Plug.Parsers.init(parsers: [:json], pass: ["*/*"], json_decoder: Jason)

  @doc false
  def dispatch(conn, router) do
    conn = Plug.Conn.fetch_query_params(conn)
    method = conn.method |> String.downcase() |> String.to_atom()

    cond do
      method == :get and path?(conn, router.__ash_rest__(:open_api)) ->
        serve_oaskit(conn, spec: Module.concat(router, OpenApi))

      method == :get and path?(conn, router.__ash_rest__(:docs)) ->
        serve_oaskit(conn, redoc3: open_api_href(conn, router))

      true ->
        route(conn, router, match(router, method, conn.path_info))
    end
  end

  defp route(conn, router, {:ok, {domain, resource, route}, path_params}) do
    # Set before the body is parsed, so the 400/413 responses of `parse_body/1`
    # can be validated against the route's OpenAPI operation too.
    conn = Plug.Conn.put_private(conn, :oaskit, %{operation_id: route.name})

    case parse_body(conn) do
      {:ok, conn} ->
        AshRest.Controller.call(conn, %{
          router: router,
          domain: domain,
          resource: resource,
          route: route,
          path_params: path_params
        })

      {:error, %Plug.Conn{} = conn} ->
        conn
    end
  end

  defp route(conn, _router, :error) do
    AshRest.Errors.send_error(
      conn,
      404,
      "no_route_found",
      "No route found for #{conn.method} #{conn.request_path}"
    )
  end

  defp parse_body(conn) do
    {:ok, Plug.Parsers.call(conn, @parsers)}
  rescue
    e in Plug.Parsers.ParseError ->
      {:error,
       AshRest.Errors.send_error(conn, 400, "invalid_body", "The request body is not valid JSON",
         exception: e
       )}

    e in Plug.Parsers.RequestTooLargeError ->
      {:error, AshRest.Errors.send_error(conn, 413, "request_too_large", Exception.message(e))}
  end

  defp path?(_conn, false), do: false
  defp path?(_conn, nil), do: false
  defp path?(conn, path), do: conn.path_info == split(path)

  defp open_api_href(conn, router) do
    Enum.join(conn.script_name ++ split(router.__ash_rest__(:open_api)), "/")
    |> then(&("/" <> &1))
  end

  if @oaskit? do
    defp serve_oaskit(conn, opts),
      do: Oaskit.SpecController.call(conn, Oaskit.SpecController.init(opts))
  else
    defp serve_oaskit(conn, _opts),
      do: AshRest.Errors.send_error(conn, 404, "no_route_found", "oaskit is not available")
  end

  @doc """
  Finds the route for `method` and `path_info` (path segments relative to the router).

  Returns `{:ok, {domain, resource, route}, path_params}` or `:error`.
  Literal segments win over `:param` segments when two routes could match.
  """
  @spec match(module(), atom(), [String.t()]) ::
          {:ok, {module(), module(), AshRest.Resource.Route.t()}, %{String.t() => String.t()}}
          | :error
  def match(router, method, path_info) do
    router
    |> compiled_routes()
    |> Enum.find_value(:error, fn {route_method, segments, entry} ->
      with true <- route_method == method,
           {:ok, params} <- match_segments(segments, path_info, %{}) do
        {:ok, entry, params}
      else
        _ -> nil
      end
    end)
  end

  defp match_segments([], [], params), do: {:ok, params}

  defp match_segments([{:param, name} | rest], [value | path], params),
    do: match_segments(rest, path, Map.put(params, name, URI.decode(value)))

  defp match_segments([literal | rest], [literal | path], params),
    do: match_segments(rest, path, params)

  defp match_segments(_, _, _), do: :error

  defp compiled_routes(router) do
    key = {__MODULE__, :routes, router}

    case :persistent_term.get(key, nil) do
      nil ->
        routes = build_routes(router)
        :persistent_term.put(key, routes)
        routes

      routes ->
        routes
    end
  end

  defp build_routes(router) do
    router
    |> AshRest.Manifest.routes()
    |> Enum.map(fn {_domain, _resource, route} = entry ->
      {route.method, compile_path(route.route), entry}
    end)
    # literal segments before params, so "/posts/drafts" beats "/posts/:id"
    |> Enum.sort_by(fn {_m, segments, _} ->
      Enum.map(segments, &if(match?({:param, _}, &1), do: 1, else: 0))
    end)
  end

  defp compile_path(path) do
    path
    |> split()
    |> Enum.map(fn
      ":" <> name -> {:param, name}
      literal -> literal
    end)
  end

  defp split(path), do: String.split(path, "/", trim: true)
end
