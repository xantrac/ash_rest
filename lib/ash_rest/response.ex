# SPDX-FileCopyrightText: 2026 ash_rest contributors
#
# SPDX-License-Identifier: MIT

defmodule AshRest.Response do
  @moduledoc """
  Renders successful ash_rpc results in the REST wire format.

    * a record is a bare JSON object with a `"type"` key (the resource's `rest.type`);
      included relationships nest inline, each record typed the same way
    * a list is `{"data": [...]}`; a page adds `"has_more"` and, when counted,
      `"count"`, plus `"limit"`/`"offset"` (offset pagination) or
      `"next_cursor"`/`"prev_cursor"` (keyset pagination)
    * action metadata is `"meta"` on the record, route metadata `"meta"` on the
      wrapper (merged into the record's `"meta"` for single records), only when
      non-empty
    * a generic action's value is sent raw, as `{"result": value}` with
      `wrap_in_result?`, or as `{"success": true}` when the action returns nothing
  """

  import Plug.Conn

  alias AshRest.Fields

  @type shape :: Fields.shape()

  @doc "Sends `body` as JSON with `status`."
  @spec send(Plug.Conn.t(), pos_integer(), term()) :: Plug.Conn.t()
  def send(conn, status, body) do
    conn
    |> put_resp_content_type("application/json")
    |> send_resp(status, Jason.encode!(body))
  end

  @doc """
  A single record: `"type"` added (recursively through the shape's children),
  nil values dropped when the resource asks for it, `meta` merged under `"meta"`.
  """
  @spec record(map() | nil, shape() | nil, map()) :: map() | nil
  def record(data, shape, meta \\ %{})
  def record(nil, _shape, _meta), do: nil

  def record(data, shape, meta) when is_map(data) do
    data
    |> typed(shape)
    |> with_meta(meta)
  end

  @doc """
  A list or page of records as the list wrapper: `{"data": [...]}` plus the
  pagination keys of an ash_rpc page map, plus `meta` under `"meta"` when non-empty.
  """
  @spec list(list() | map(), shape() | nil, map()) :: map()
  def list(data, shape, meta \\ %{})

  def list(%{"results" => results} = page, shape, meta) when is_list(results) do
    %{"data" => typed(results, shape), "has_more" => page["has_more"] || false}
    |> put_count(page["count"])
    |> put_pagination(page)
    |> with_meta(meta)
  end

  def list(records, shape, meta) when is_list(records) do
    with_meta(%{"data" => typed(records, shape)}, meta)
  end

  def list(nil, _shape, meta), do: with_meta(%{"data" => []}, meta)

  @doc """
  A generic action's result. `wrapped?` is the route's `wrap_in_result?`;
  `void?` is true when the action declares no return value.
  """
  @spec value(term(), boolean(), boolean()) :: term()
  def value(_data, _wrapped?, true), do: %{"success" => true}
  def value(data, true, false), do: %{"result" => data}
  def value(data, false, false), do: data

  @doc "True when `data` is an ash_rpc page map rather than a plain list of records."
  @spec page?(term()) :: boolean()
  def page?(%{"results" => results, "type" => type}) when is_list(results),
    do: to_string(type) in ["offset", "keyset"]

  def page?(_), do: false

  @doc """
  Adds `"type"` to every record described by `shape`, walking included
  relationships (lists, nested pages and to-one records alike), and drops nil
  values on resources with `include_nil_values? false`.
  """
  @spec typed(term(), shape() | nil) :: term()
  def typed(data, nil), do: data
  def typed(list, shape) when is_list(list), do: Enum.map(list, &typed(&1, shape))

  def typed(%{"results" => results} = page, shape) when is_list(results),
    do: %{page | "results" => typed(results, shape)}

  def typed(%{} = record, shape) do
    record =
      Enum.reduce(shape.children, record, fn {key, child_shape}, acc ->
        case Map.fetch(acc, key) do
          {:ok, value} -> Map.put(acc, key, typed(value, child_shape))
          :error -> acc
        end
      end)

    record =
      if shape.include_nil?,
        do: record,
        else: Map.reject(record, fn {_key, value} -> is_nil(value) end)

    case shape.type do
      nil -> record
      type -> Map.put(record, "type", type)
    end
  end

  def typed(other, _shape), do: other

  defp with_meta(data, meta) when meta == %{} or is_nil(meta), do: data

  defp with_meta(data, meta) when is_map(data) do
    existing = Map.get(data, "meta") || %{}
    Map.put(data, "meta", Map.merge(existing, meta))
  end

  defp put_count(wrapper, count) when is_integer(count), do: Map.put(wrapper, "count", count)
  defp put_count(wrapper, _count), do: wrapper

  defp put_pagination(wrapper, %{"type" => type} = page) do
    case to_string(type) do
      "offset" ->
        Map.merge(wrapper, %{"limit" => page["limit"], "offset" => page["offset"] || 0})

      "keyset" ->
        {prev, next} = keyset_cursors(page)
        Map.merge(wrapper, %{"next_cursor" => next, "prev_cursor" => prev})

      _ ->
        wrapper
    end
  end

  defp put_pagination(wrapper, _page), do: wrapper

  # Mirrors ash_json_api's keyset link rules: the first page (no cursor given)
  # has no previous cursor; paging backwards with `before` assumes more ahead;
  # cursors are nil when there are no results in that direction.
  defp keyset_cursors(%{"results" => []}), do: {nil, nil}

  defp keyset_cursors(page) do
    first = page["previous_page"]
    last = page["next_page"]
    more? = page["has_more"] || false
    direction = {page["after"], page["before"]}

    case direction do
      # first page
      {nil, nil} -> {nil, if(more?, do: last)}
      # paging backwards
      {nil, _before} -> {if(more?, do: first), last}
      # paging forwards
      {_after, _} -> {first, if(more?, do: last)}
    end
  end
end
