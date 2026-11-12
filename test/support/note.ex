# SPDX-FileCopyrightText: 2026 ash_rest contributors
#
# SPDX-License-Identifier: MIT

defmodule AshRest.TestApp.Note do
  @moduledoc false
  # Acceptance fixture: `include_nil_values? false`, field and argument renames,
  # route-level `metadata`/`modify_conn`, `read_action`, `paginate?`,
  # `enable_filter?`/`enable_sort?`, and generic routes over every action type.
  use Ash.Resource,
    domain: AshRest.TestApp.Domain,
    data_layer: Ash.DataLayer.Ets,
    extensions: [AshRest]

  ets do
    private? true
  end

  rest do
    type "note"
    base "/notes"
    include_nil_values? false
    field_names body: "text", pinned?: "pinned"
    argument_names echo: [loud?: "loud"]

    routes do
      get :read,
        metadata: fn subject, record, _request ->
          %{action: to_string(subject.action), title_length: String.length(record["title"])}
        end

      index :read,
        metadata: fn _subject, records, _request -> %{returned: length(records)} end,
        modify_conn: fn conn, subject, records, _request ->
          conn
          |> Plug.Conn.put_resp_header("x-note-count", to_string(length(records)))
          |> Plug.Conn.put_resp_header("x-actor", inspect(subject.actor))
        end

      index :paged, route: "/paged", name: "note.paged", paginate?: false

      index :read,
        route: "/unfiltered",
        name: "note.unfiltered",
        enable_filter?: false,
        enable_sort?: false

      index :search, route: "/search_index", name: "note.search_index", query_params: [:q]
      post :create
      patch :update
      patch :update, route: "/:id/pinned", name: "note.update_pinned", read_action: :pinned
      delete :destroy
      route :put, "/:id", :update, name: "note.put"
      route :post, "/:id/archive", :destroy, name: "note.archive"
      route :post, "/titled/:title", :create, name: "note.create_titled"
      route :get, "/search", :search, query_params: [:q]
      route :get, "/by_title/:title", :by_title
      route :get, "/latest", :latest
      route :post, "/echo", :echo
      route :post, "/explode", :explode
    end
  end

  attributes do
    uuid_primary_key :id
    attribute :title, :string, public?: true, allow_nil?: false
    attribute :body, :string, public?: true
    attribute :pinned?, :boolean, public?: true, default: false
    attribute :priority, :integer, public?: true
  end

  actions do
    defaults [:read, :destroy, create: :*, update: :*]

    read :paged do
      pagination offset?: true, countable: true, default_limit: 2, required?: false
    end

    read :pinned do
      filter expr(pinned? == true)
    end

    read :search do
      argument :q, :string, allow_nil?: false
      filter expr(contains(title, ^arg(:q)))
    end

    read :by_title do
      get? true
      argument :title, :string, allow_nil?: false
      filter expr(title == ^arg(:title))
    end

    action :latest, :struct do
      constraints instance_of: __MODULE__

      run fn _input, _context ->
        {:ok, __MODULE__ |> Ash.read!() |> Enum.max_by(& &1.title, fn -> nil end)}
      end
    end

    action :echo, :string do
      argument :text, :string, allow_nil?: false
      argument :loud?, :boolean, default: false

      run fn input, _context ->
        text = input.arguments.text
        {:ok, if(input.arguments.loud?, do: String.upcase(text), else: text)}
      end
    end

    action :explode, :string do
      run fn _input, _context -> raise "boom" end
    end
  end
end
