# SPDX-FileCopyrightText: 2026 ash_rest contributors
#
# SPDX-License-Identifier: MIT

defmodule AshRest.TestHelpersTest do
  use ExUnit.Case, async: false

  import AshRest.Test

  alias AshRest.TestApp.{Author, Post, Router}

  defmodule HtmlRouter do
    @moduledoc false
    # A plug answering every request with HTML.
    @behaviour Plug

    @impl true
    def init(opts), do: opts

    @impl true
    def call(conn, _opts) do
      conn
      |> Plug.Conn.put_resp_content_type("text/html")
      |> Plug.Conn.send_resp(200, "<p>hi</p>")
    end
  end

  defp create_author(attrs \\ %{}), do: Ash.create!(Author, Map.merge(%{name: "Ada"}, attrs))

  defp create_post(attrs \\ %{}) do
    author = create_author()
    Ash.create!(Post, Map.merge(%{title: "Hello", author_id: author.id}, attrs))
  end

  describe "requests" do
    test "get returns the conn with the decoded body in assigns.json" do
      post = create_post()

      conn = get(Router, "/posts/#{post.id}")

      assert conn.status == 200
      assert %{"id" => id, "type" => "post"} = conn.assigns.json
      assert id == post.id
      assert json(conn) == conn.assigns.json
    end

    test "post encodes the body and expects 201" do
      author = create_author()

      conn = post(Router, "/posts", %{title: "Created", author_id: author.id})

      assert conn.status == 201
      assert json(conn)["title"] == "Created"
      assert ["application/json"] = Plug.Conn.get_req_header(conn, "content-type")
    end

    test "patch, put and delete" do
      post = create_post()

      assert %{"title" => "Renamed"} =
               Router |> patch("/posts/#{post.id}", %{title: "Renamed"}) |> json()

      # openapi: false - the deleted post lacks comment_count, a known spec
      # mismatch covered by test/acceptance/records_test.exs.
      assert %{"id" => _} = Router |> delete("/posts/#{post.id}", openapi: false) |> json()

      Router
      |> put("/posts/#{post.id}", %{title: "x"}, status: 404)
      |> assert_error(404, "no_route_found")
    end

    test ":status asserts the response status and shows the body on mismatch" do
      error =
        assert_raise ExUnit.AssertionError, fn ->
          get(Router, "/posts/#{Ash.UUID.generate()}")
        end

      assert error.message =~ "to respond with status 200, got 404"
      assert error.message =~ "not_found"

      get(Router, "/posts/#{Ash.UUID.generate()}", status: 404)
    end

    test ":query is encoded and appended to the path" do
      for title <- ~w(A B C), do: create_post(%{title: title})

      conn = get(Router, "/posts", query: [filter: [title: "B"]])
      assert [%{"title" => "B"}] = json(conn)["data"]

      conn = get(Router, "/posts?sort=-title", query: %{filter: %{title: %{in: ["A", "C"]}}})
      assert Enum.map(json(conn)["data"], & &1["title"]) == ["C", "A"]
    end

    test ":actor and :tenant are set with Ash.PlugHelpers" do
      Router |> get("/secrets", status: 403) |> assert_error(403, "forbidden")

      conn = get(Router, "/secrets", actor: %{role: :admin}, tenant: "org_1")

      assert json(conn) == %{"data" => []}
      assert Ash.PlugHelpers.get_actor(conn) == %{role: :admin}
      assert Ash.PlugHelpers.get_tenant(conn) == "org_1"
    end

    test ":headers are added to the request" do
      conn = get(Router, "/posts", headers: [{"X-Request-Id", "abc"}])
      assert Plug.Conn.get_req_header(conn, "x-request-id") == ["abc"]
    end

    test ":content_type and :raw_body" do
      Router
      |> post("/posts", nil, raw_body: "title=x", content_type: "text/plain", status: 415)
      |> assert_error(415, "unsupported_media_type")

      Router
      |> post("/posts", nil, raw_body: "{not json", status: 400)
      |> assert_error(400, "invalid_body")
    end

    test "a non-JSON response fails the content type assertion" do
      router = __MODULE__.HtmlRouter

      error = assert_raise ExUnit.AssertionError, fn -> get(router, "/") end
      assert error.message =~ "to respond with application/json"
    end

    test "json/1 decodes the body of any sent conn" do
      conn =
        Plug.Test.conn(:get, "/posts")
        |> Router.call([])

      refute Map.has_key?(conn.assigns, :json)
      assert json(conn) == %{"data" => []}
    end
  end

  describe ":openapi" do
    test "validates responses against the router's OpenApi module" do
      post = create_post()

      get(Router, "/posts/#{post.id}", openapi: true)
      get(Router, "/posts", openapi: Router.OpenApi)
      get(Router, "/posts/#{Ash.UUID.generate()}", status: 404, openapi: true)
    end

    test "responses without an operation are not validated" do
      Router
      |> get("/nothing/here", status: 404, openapi: true)
      |> assert_error(404, "no_route_found")
    end

    test "validate_openapi/1 sets the default" do
      previous = :persistent_term.get({AshRest.Test, :openapi}, false)
      on_exit(fn -> AshRest.Test.validate_openapi(previous) end)

      assert :ok = AshRest.Test.validate_openapi(true)

      conn = get(Router, "/posts")
      assert json(conn) == %{"data" => []}

      assert :ok = AshRest.Test.validate_openapi(false)
      assert %{"data" => []} = json(get(Router, "/posts"))
    end
  end

  describe "assert_record/2" do
    test "matches an inline pattern, binding variables and using pins" do
      post = create_post(%{title: "Pattern"})
      post_id = post.id
      conn = get(Router, "/posts/#{post.id}")

      assert_record(conn, %{"id" => ^post_id, "title" => "Pattern", "author_id" => author_id})
      assert author_id == post.author_id

      assert_raise ExUnit.AssertionError, fn ->
        assert_record(conn, %{"title" => "Other"})
      end
    end

    test "compares a runtime map as a subset after a JSON round trip" do
      post = create_post(%{title: "Subset", score: 3})
      conn = get(Router, "/posts/#{post.id}")

      expected = %{title: "Subset", score: 3, status: :draft}
      assert %{"type" => "post"} = assert_record(conn, expected)

      error =
        assert_raise ExUnit.AssertionError, fn ->
          assert_record(conn, Map.put(expected, :score, 4))
        end

      assert error.message =~ "Expected the response to contain"
    end

    test "fails on lists and errors" do
      conn = get(Router, "/posts")

      assert_raise ExUnit.AssertionError, ~r/Expected a record, got a list/, fn ->
        assert_record(conn, %{})
      end

      conn = get(Router, "/posts/#{Ash.UUID.generate()}", status: 404)

      assert_raise ExUnit.AssertionError, ~r/got an error/, fn ->
        assert_record(conn, %{"id" => _})
      end
    end
  end

  describe "assert_list/2" do
    setup do
      for title <- ~w(A B C), do: create_post(%{title: title})
      :ok
    end

    test "with a count" do
      conn = get(Router, "/posts?sort=title")
      assert [%{"title" => "A"} | _] = assert_list(conn, 3)

      assert_raise ExUnit.AssertionError, ~r/Expected 2 records, got 3/, fn ->
        assert_list(conn, 2)
      end
    end

    test "with a list pattern" do
      conn = get(Router, "/posts?sort=title")
      [_, %{"id" => id}, _] = assert_list(conn, [%{"title" => "A"}, %{"title" => "B"}, _])
      assert is_binary(id)

      assert_raise ExUnit.AssertionError, fn ->
        assert_list(conn, [%{"title" => "B"} | _])
      end
    end

    test "with a map pattern for the wrapper" do
      conn = get(Router, "/posts/offset?page[limit]=2&page[count]=true&sort=title")

      assert [_, _] =
               assert_list(conn, %{
                 "has_more" => true,
                 "count" => 3,
                 "limit" => 2,
                 "data" => [_, _]
               })
    end

    test "with runtime values" do
      conn = get(Router, "/posts/offset?page[limit]=2&sort=title")

      expected = [%{title: "A"}, %{title: "B"}]
      assert length(assert_list(conn, expected)) == 2

      wrapper = %{has_more: true, offset: 0}
      assert_list(conn, wrapper)

      assert_raise ExUnit.AssertionError, fn ->
        assert_list(conn, Enum.reverse(expected))
      end
    end

    test "fails on a record" do
      post = create_post()
      conn = get(Router, "/posts/#{post.id}")

      assert_raise ExUnit.AssertionError, ~r/Expected a list response/, fn ->
        assert_list(conn, 1)
      end
    end
  end

  describe "assert_error/3 and assert_error_detail/3" do
    test "check the envelope and its details" do
      conn = post(Router, "/posts", %{}, status: 400)

      assert %{"message" => "attribute title is required"} = assert_error(conn, 400, "required")

      assert %{"message" => _} = assert_error_detail(conn, "title", "required")

      assert_raise ExUnit.AssertionError, ~r/Expected error code "not_found"/, fn ->
        assert_error(conn, 400, "not_found")
      end

      assert_raise ExUnit.AssertionError, ~r/Expected status 404/, fn ->
        assert_error(conn, 404, "required")
      end

      assert_raise ExUnit.AssertionError, ~r/Expected an error detail/, fn ->
        assert_error_detail(conn, "body", "required")
      end
    end

    test "fail on success responses" do
      conn = get(Router, "/posts")

      assert_raise ExUnit.AssertionError, ~r/Expected an error response/, fn ->
        assert_error(conn, 400, "required")
      end
    end
  end
end
