# SPDX-FileCopyrightText: 2026 ash_rest contributors
#
# SPDX-License-Identifier: MIT

defmodule AshRest.Params do
  @moduledoc """
  Turns the query string of a request into the pieces the controller hands to
  ash_rpc.

    * `filter` - Plug already parses `filter[title][eq]=x` into the nested map
      ash_rpc expects (`%{"title" => %{"eq" => "x"}}`); values stay strings and
      ash_rpc casts them with the field's type. Maps whose keys are all
      non-negative integers (`filter[or][0][title]=A&filter[or][1][title]=B`)
      become lists ordered by index, at any depth, so `and`/`or` can be written
      in the query string.
    * `sort` - a string such as `-created_at,title`, passed through. An empty
      `sort=` means no sort.
    * `page` - `limit`/`offset` become integers, `count` a boolean, `after`/`before`
      stay strings. Anything else is `invalid_pagination`.
    * `include` - `author,comments.author` becomes `[author: [], comments: [author: []]]`
      and is checked against the allow-list given in `opts[:includes]`.
    * the route's `query_params` are collected under `:input`.

  Every other key is `unsupported_query_parameter`.
  """

  @type kind :: :list | :record | :value

  @type parsed :: %{
          filter: map() | nil,
          sort: String.t() | nil,
          page: map() | nil,
          include: keyword(),
          input: %{String.t() => term()}
        }

  @type error :: {code :: String.t(), message :: String.t(), details :: [map()]}

  @page_keys ~w(limit offset count after before)

  @doc """
  Parses `query` (the conn's `query_params`).

  Options:

    * `:kind` - `:list` (filter, sort, page and include apply), `:record` (only
      include applies) or `:value` (none apply). Defaults to `:value`.
    * `:paginate?` - when `false`, `page` is not accepted on `:list` routes.
      Defaults to `true`.
    * `:includes` - the allowed include tree, a nested keyword list with `[]`
      leaves, keyed by relationship name.
    * `:include_names` - `%{relationship => wire_name}` overrides, so a renamed
      relationship is requested by its wire name.
    * `:query_params` - `%{wire_name => wire_name}` of the route's `query_params`;
      their values are returned under `:input`.
  """
  @spec parse(%{String.t() => term()}, keyword()) :: {:ok, parsed()} | {:error, error()}
  def parse(query, opts) when is_map(query) do
    kind = Keyword.get(opts, :kind, :value)
    query_params = Keyword.get(opts, :query_params, %{})

    allowed =
      case kind do
        :list ->
          if Keyword.get(opts, :paginate?, true),
            do: ~w(filter sort page include),
            else: ~w(filter sort include)

        :record ->
          ~w(include)

        :value ->
          []
      end

    with :ok <- check_unknown(query, allowed, query_params),
         {:ok, page} <- parse_page(Map.get(query, "page")),
         {:ok, filter} <- parse_filter(Map.get(query, "filter")),
         {:ok, sort} <- parse_sort(Map.get(query, "sort")),
         {:ok, include} <- parse_include(Map.get(query, "include"), opts) do
      {:ok,
       %{
         filter: filter,
         sort: sort,
         page: page,
         include: include,
         input: Map.take(query, Map.keys(query_params))
       }}
    end
  end

  defp check_unknown(query, allowed, query_params) do
    query
    |> Map.keys()
    |> Enum.reject(&(&1 in allowed or Map.has_key?(query_params, &1)))
    |> case do
      [] ->
        :ok

      ["fields" | _] ->
        {:error,
         {"unsupported_query_parameter",
          "The fields query parameter (sparse fieldsets) is not supported", []}}

      [key | _] ->
        {:error,
         {"unsupported_query_parameter", "Unsupported query parameter: #{key}",
          [
            %{
              "field" => key,
              "code" => "unsupported_query_parameter",
              "message" => "is not supported"
            }
          ]}}
    end
  end

  @doc "Coerces the `page` query parameter. `nil` stays `nil`."
  @spec parse_page(term()) :: {:ok, map() | nil} | {:error, error()}
  def parse_page(nil), do: {:ok, nil}

  def parse_page(page) when is_map(page) do
    Enum.reduce_while(page, {:ok, %{}}, fn {key, value}, {:ok, acc} ->
      case page_value(key, value) do
        {:ok, coerced} -> {:cont, {:ok, Map.put(acc, key, coerced)}}
        {:error, message} -> {:halt, {:error, page_error(key, message)}}
      end
    end)
  end

  def parse_page(_other) do
    {:error,
     {"invalid_pagination", "page must be an object, e.g. page[limit]=10",
      [%{"field" => "page", "code" => "invalid_pagination", "message" => "must be an object"}]}}
  end

  defp page_value(key, value) when key in ["limit", "offset"] do
    case value do
      value when is_integer(value) and value >= 0 ->
        {:ok, value}

      value when is_binary(value) ->
        case Integer.parse(value) do
          {int, ""} when int >= 0 -> {:ok, int}
          _ -> {:error, "must be a non-negative integer"}
        end

      _ ->
        {:error, "must be a non-negative integer"}
    end
  end

  defp page_value("count", value) do
    case value do
      value when is_boolean(value) -> {:ok, value}
      "true" -> {:ok, true}
      "false" -> {:ok, false}
      _ -> {:error, "must be true or false"}
    end
  end

  defp page_value(key, value) when key in ["after", "before"] do
    if is_binary(value) and value != "",
      do: {:ok, value},
      else: {:error, "must be a cursor string"}
  end

  defp page_value(key, _value) when key in @page_keys, do: {:error, "is not supported"}
  defp page_value(_key, _value), do: {:error, "is not a pagination parameter"}

  defp page_error(key, message) do
    {"invalid_pagination", "page[#{key}] #{message}",
     [%{"field" => "page.#{key}", "code" => "invalid_pagination", "message" => message}]}
  end

  defp parse_filter(nil), do: {:ok, nil}
  defp parse_filter(filter) when is_map(filter), do: {:ok, indexed_lists(filter)}

  defp parse_filter(_other) do
    {:error,
     {"invalid_filter", "filter must be an object, e.g. filter[title][eq]=hello",
      [%{"field" => "filter", "code" => "invalid_filter", "message" => "must be an object"}]}}
  end

  defp parse_sort(nil), do: {:ok, nil}
  defp parse_sort(""), do: {:ok, nil}
  defp parse_sort(sort) when is_binary(sort), do: {:ok, sort}

  defp parse_sort(_other) do
    {:error,
     {"invalid_sort", "sort must be a string, e.g. sort=-created_at,title",
      [%{"field" => "sort", "code" => "invalid_sort", "message" => "must be a string"}]}}
  end

  @doc """
  Turns every map whose keys are all non-negative integer strings into a list
  ordered by those integers, recursively. Plug parses `filter[or][0][a]=1` as
  `%{"or" => %{"0" => %{"a" => "1"}}}`; ash_rpc wants `%{"or" => [%{"a" => "1"}]}`.

      iex> AshRest.Params.indexed_lists(%{"or" => %{"1" => %{"b" => "2"}, "0" => %{"a" => "1"}}})
      %{"or" => [%{"a" => "1"}, %{"b" => "2"}]}
  """
  @spec indexed_lists(term()) :: term()
  def indexed_lists(map) when is_map(map) and map_size(map) > 0 do
    case indexed_keys(Map.keys(map)) do
      {:ok, indexes} ->
        indexes
        |> Enum.sort_by(fn {index, _key} -> index end)
        |> Enum.map(fn {_index, key} -> indexed_lists(Map.fetch!(map, key)) end)

      :error ->
        Map.new(map, fn {key, value} -> {key, indexed_lists(value)} end)
    end
  end

  def indexed_lists(list) when is_list(list), do: Enum.map(list, &indexed_lists/1)
  def indexed_lists(other), do: other

  defp indexed_keys(keys) do
    Enum.reduce_while(keys, {:ok, []}, fn key, {:ok, acc} ->
      with true <- is_binary(key),
           {index, ""} when index >= 0 <- Integer.parse(key) do
        {:cont, {:ok, [{index, key} | acc]}}
      else
        _ -> {:halt, :error}
      end
    end)
  end

  @doc """
  Parses `include=author,comments.author` into `[author: [], comments: [author: []]]`,
  checking every path against `opts[:includes]` (see `parse/2`).
  """
  @spec parse_include(term(), keyword()) :: {:ok, keyword()} | {:error, error()}
  def parse_include(nil, _opts), do: {:ok, []}
  def parse_include("", _opts), do: {:ok, []}

  def parse_include(include, opts) when is_binary(include) do
    allowed = Keyword.get(opts, :includes, [])
    names = Keyword.get(opts, :include_names, %{})

    include
    |> String.split(",", trim: true)
    |> Enum.map(&String.split(&1, ".", trim: true))
    |> Enum.reduce_while({:ok, []}, fn path, {:ok, tree} ->
      case add_path(tree, path, allowed, names, []) do
        {:ok, tree} -> {:cont, {:ok, tree}}
        {:error, bad_path} -> {:halt, {:error, include_error(bad_path)}}
      end
    end)
  end

  def parse_include(_other, _opts), do: {:error, include_error(["include"])}

  defp add_path(tree, [], _allowed, _names, _seen), do: {:ok, tree}

  defp add_path(tree, [segment | rest], allowed, names, seen) do
    allowed
    |> Enum.find(fn {rel, _} -> wire_name(rel, names) == segment end)
    |> case do
      nil ->
        {:error, Enum.reverse([segment | seen])}

      {rel, sub_allowed} ->
        with {:ok, subtree} <-
               add_path(Keyword.get(tree, rel, []), rest, sub_allowed, names, [segment | seen]) do
          {:ok, Keyword.put(tree, rel, subtree)}
        end
    end
  end

  defp wire_name(rel, names), do: Map.get(names, rel, to_string(rel))

  defp include_error(path) do
    dotted = Enum.join(path, ".")

    {"invalid_include", "#{dotted} cannot be included",
     [
       %{
         "field" => "include",
         "code" => "invalid_include",
         "message" => "#{dotted} cannot be included"
       }
     ]}
  end
end
