# SPDX-FileCopyrightText: 2026 ash_rest contributors
#
# SPDX-License-Identifier: MIT

defmodule AshRest.Errors do
  @moduledoc """
  Renders the error envelope.

      {"error": {"status": 400, "code": "required", "message": "attribute title is required",
                 "details": [{"field": "title", "code": "required", "message": "attribute title is required"}]}}

  Errors found before the request reaches ash_rpc (no route, bad JSON, bad query
  params) are sent with `send_error/5`. Failure responses from ash_rpc are
  converted with `send_rpc_errors/2`: the status comes from the first error's
  type (`status_for/1`), `code` is that type, and `message` is its message with
  `%{var}` placeholders filled from `vars`.
  """

  import Plug.Conn

  # Ash.Error.Forbidden exceptions as named by ash_rpc's show_raised_errors? path.
  @raised_forbidden_types ~w(policy must_pass_strict_check domain_requires_actor)

  @type detail :: %{
          optional(:field) => String.t() | nil,
          code: String.t(),
          message: String.t()
        }

  @doc "Sends a locally built error. `opts` may carry `details: [detail]`."
  @spec send_error(Plug.Conn.t(), pos_integer(), String.t(), String.t(), keyword()) ::
          Plug.Conn.t()
  def send_error(conn, status, code, message, opts \\ []) do
    error = %{"status" => status, "code" => code, "message" => message}

    error =
      case Keyword.get(opts, :details) do
        details when is_list(details) and details != [] ->
          Map.put(error, "details", Enum.map(details, &render_detail/1))

        _ ->
          error
      end

    send_json(conn, status, %{"error" => error})
  end

  @doc """
  Sends the ash_rpc errors of a `%{"success" => false, "errors" => [...]}` response.

  The error maps are string-keyed (ash_rpc formats them with the snake_case
  output formatter): `type`, `message`, `short_message`, `vars`, `fields`, `path`.
  `details` is omitted when there is exactly one error and it names no field.

  An empty list (every error dropped by an error handler) is a
  `500 internal_error`.

  Options:

    * `:strip_path` - a list of leading path segments removed from every
      error's `path` before it is rendered as `details[].field` (the
      relationship envelope of a `related` route).
  """
  @spec send_rpc_errors(Plug.Conn.t(), [map()], keyword()) :: Plug.Conn.t()
  def send_rpc_errors(conn, errors, opts \\ [])

  def send_rpc_errors(conn, [], _opts) do
    send_error(conn, 500, "internal_error", "An error occurred")
  end

  def send_rpc_errors(conn, [first | _] = errors, opts) do
    strip = Keyword.get(opts, :strip_path, [])
    status = status_for(code(first))
    details = Enum.map(errors, &rpc_detail(&1, strip))

    error = %{
      "status" => status,
      "code" => code(first),
      "message" => message(first)
    }

    error =
      case details do
        [%{"field" => nil}] -> error
        _ -> Map.put(error, "details", details)
      end

    send_json(conn, status, %{"error" => error})
  end

  @doc "The HTTP status for an ash_rpc error type."
  @spec status_for(String.t() | nil) :: pos_integer()
  def status_for(type) when type in ["not_found", "action_not_found"], do: 404
  def status_for(type) when type in ["forbidden", "forbidden_field"], do: 403
  def status_for(type) when type in ["unknown_error", "internal_error"], do: 500
  def status_for(type) when type in @raised_forbidden_types, do: 403
  def status_for(_type), do: 400

  @doc """
  The error code of an ash_rpc error: its `type`, or `unknown_error` without one.

  With `show_raised_errors?` ash_rpc names errors after their exception module
  instead of their ash_rpc type, so a policy failure arrives as `"policy"`;
  the forbidden exceptions are mapped back to `"forbidden"`.
  """
  @spec code(map()) :: String.t()
  def code(%{} = error) do
    case error["type"] do
      type when type in @raised_forbidden_types -> "forbidden"
      type when is_binary(type) and type != "" -> type
      _ -> "unknown_error"
    end
  end

  @doc "The error's message with `%{var}` placeholders interpolated from `vars`."
  @spec message(map()) :: String.t()
  def message(%{} = error) do
    vars = error["vars"] || %{}

    template =
      case error["message"] do
        message when is_binary(message) and message != "" -> message
        _ -> error["short_message"] || error["type"] || "Something went wrong"
      end

    Regex.replace(~r/%\{([^}]+)\}/, template, fn whole, name ->
      case Map.fetch(vars, name) do
        {:ok, value} -> to_text(value)
        :error -> whole
      end
    end)
  end

  @doc false
  def send_json(conn, status, body) do
    conn
    |> put_resp_content_type("application/json")
    |> send_resp(status, Jason.encode!(body))
  end

  defp rpc_detail(error, strip) do
    %{
      "field" => field(error, strip),
      "code" => code(error),
      "message" => message(error)
    }
  end

  # The client path to the error, then the field names it reports, dotted.
  defp field(error, strip) do
    fields =
      case error["fields"] do
        [_ | _] = fields -> [Enum.map_join(fields, ",", &to_text/1)]
        _ -> []
      end

    path =
      case error["path"] do
        path when is_list(path) -> path |> Enum.map(&to_text/1) |> strip_prefix(strip)
        _ -> []
      end

    case path ++ fields do
      [] -> nil
      segments -> Enum.join(segments, ".")
    end
  end

  defp strip_prefix(path, []), do: path

  defp strip_prefix(path, prefix) do
    if List.starts_with?(path, prefix), do: Enum.drop(path, length(prefix)), else: path
  end

  defp render_detail(detail) do
    detail
    |> Map.new(fn {key, value} -> {to_string(key), value} end)
    |> Map.take(["field", "code", "message"])
  end

  defp to_text(value) when is_binary(value), do: value
  defp to_text(value) when is_atom(value) or is_number(value), do: to_string(value)
  defp to_text(value) when is_list(value), do: Enum.map_join(value, ", ", &to_text/1)
  defp to_text(value), do: inspect(value)
end
