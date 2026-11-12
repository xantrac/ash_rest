# SPDX-FileCopyrightText: 2026 ash_rest contributors
#
# SPDX-License-Identifier: MIT

defmodule AshRest.Acceptance.GenericRoutesTest do
  @moduledoc false
  # `route` entries over every action type, `query_params`, path params,
  # argument renames, and route-level `metadata` / `modify_conn`.
  use AshRest.AcceptanceCase, async: true

  describe "generic actions" do
    test "a raw value, with query_params as input" do
      conn = get(Router, "/posts/word_count?text=one%20two%20three")
      assert conn.resp_body == "3"
      assert json(conn) == 3

      Router
      |> get("/posts/word_count", status: 400)
      |> assert_error_detail("text", "required")

      Router
      |> get("/posts/word_count?text=a&extra=1", status: 400)
      |> assert_error_detail("extra", "unsupported_query_parameter")

      Router
      |> get("/posts/word_count?text=a&include=author", status: 400)
      |> assert_error_detail("include", "unsupported_query_parameter")
    end

    test "wrap_in_result? wraps a typed map" do
      conn = post(Router, "/posts/stats", %{}, status: 200)
      assert json(conn) == %{"result" => %{"total" => 42}}
    end

    test "an action without a return type answers success" do
      conn = post(Router, "/posts/ping", %{}, status: 200)
      assert json(conn) == %{"success" => true}

      conn = post(Router, "/posts/ping", nil, status: 200)
      assert json(conn) == %{"success" => true}
    end

    test "a string return value and renamed arguments" do
      assert Router |> post("/notes/echo", %{text: "hi"}, status: 200) |> json() == "hi"

      assert Router |> post("/notes/echo", %{text: "hi", loud: true}, status: 200) |> json() ==
               "HI"

      Router
      |> post("/notes/echo", %{text: "hi", loud?: true}, status: 400)
      |> assert_error_detail("loud?", "unknown_input")
    end

    test "a resource return value renders as a typed record" do
      create_note(%{title: "a"})
      create_note(%{title: "z", priority: 3})

      Router
      |> get("/notes/latest")
      |> assert_record(%{"type" => "note", "title" => "z", "priority" => 3})
    end

    @tag capture_log: true
    test "an exception is a generic 500" do
      Router
      |> post("/notes/explode", %{}, status: 500)
      |> assert_error(500, "unknown_error")
      |> then(&assert(&1["message"] == "Something went wrong"))
    end
  end

  describe "update and destroy actions" do
    test "an update by id renders the record with the action's metadata" do
      post = create_post(create_author())
      id = post.id

      Router
      |> post("/posts/#{id}/publish", %{}, status: 200)
      |> assert_record(%{
        "id" => ^id,
        "type" => "post",
        "status" => "published",
        "published?" => true,
        "meta" => %{"published_by" => "ash_rest"}
      })

      Router
      |> post("/posts/#{Ash.UUID.generate()}/publish", %{}, status: 404)
      |> assert_error(404, "not_found")

      Router
      |> post("/posts/#{id}/publish", %{title: "no"}, status: 400)
      |> assert_error_detail("title", "unknown_input")
    end

    test "a destroy by id renders the destroyed record" do
      note = create_note(%{title: "Archived"})

      Router
      |> post("/notes/#{note.id}/archive", %{}, status: 200)
      |> assert_record(%{"title" => "Archived", "type" => "note"})

      assert {:error, _} = Ash.get(Note, note.id)
    end
  end

  describe "create actions" do
    test "path params are merged into the input; the response is 200" do
      Router
      |> post("/notes/titled/From%20path", %{text: "body"}, status: 200)
      |> assert_record(%{"title" => "From path", "text" => "body", "type" => "note"})
    end
  end

  describe "read actions" do
    test "a list, with query_params as arguments" do
      create_note(%{title: "Alpha"})
      create_note(%{title: "Alphabet"})
      create_note(%{title: "Beta"})

      assert Router |> get("/notes/search?q=lph&sort=-title") |> titles() == ["Alphabet", "Alpha"]

      assert Router |> get("/notes/search?q=lph&filter[title]=Alpha") |> titles() == ["Alpha"]

      Router
      |> get("/notes/search", status: 400)
      |> assert_error_detail("q", "required")

      Router
      |> get("/notes/search?q=a&page[limit]=1", status: 400)
      |> assert_error(400, "pagination_not_supported")
    end

    # A `route` to a `get? true` read action is a record route: one record,
    # 404 when none matches, no list query parameters.
    test "a get? read action renders a record" do
      create_note(%{title: "Exact"})

      Router
      |> get("/notes/by_title/Exact")
      |> assert_record(%{"title" => "Exact", "type" => "note"})

      Router
      |> get("/notes/by_title/Missing", status: 404)
      |> assert_error(404, "not_found")

      Router
      |> get("/notes/by_title/Exact?page[limit]=1", status: 400)
      |> assert_error_detail("page", "unsupported_query_parameter")
    end

    test "query_params on an index route" do
      create_note(%{title: "Alpha"})

      assert Router |> get("/notes/search_index?q=lph") |> titles() == ["Alpha"]
    end
  end

  describe "route metadata and modify_conn" do
    test "metadata on a record is merged under meta" do
      note = create_note(%{title: "Meta"})

      Router
      |> get("/notes/#{note.id}")
      |> assert_record(%{"meta" => %{"action" => "read", "title_length" => 4}})
    end

    test "metadata on a list is a top-level meta, modify_conn sets headers" do
      create_note(%{title: "One"})
      create_note(%{title: "Two"})

      conn = get(Router, "/notes", actor: %{id: "me"})

      assert_list(conn, %{"meta" => %{"returned" => 2}, "data" => [_, _]})
      assert Plug.Conn.get_resp_header(conn, "x-note-count") == ["2"]
      assert Plug.Conn.get_resp_header(conn, "x-actor") == [inspect(%{id: "me"})]
    end

    test "metadata sees the records of the page, modify_conn is skipped on errors" do
      conn = get(Router, "/notes?filter[title]=none")
      assert_list(conn, %{"meta" => %{"returned" => 0}, "data" => []})

      conn = get(Router, "/notes?filter[nope]=1", status: 400)
      assert Plug.Conn.get_resp_header(conn, "x-note-count") == []
      refute Map.has_key?(json(conn), "meta")
    end
  end
end
