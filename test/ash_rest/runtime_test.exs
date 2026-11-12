# SPDX-FileCopyrightText: 2026 ash_rest contributors
#
# SPDX-License-Identifier: MIT

defmodule AshRest.RuntimeTest do
  @moduledoc false
  # Drives AshRest.TestApp.Router through Plug.Test to prove the runtime core:
  # Controller, Params, Fields, Response and Errors.
  use ExUnit.Case, async: false

  import Plug.Conn
  import Plug.Test

  alias AshRest.TestApp.{Author, Comment, Post, Router}

  defp request(method, path, body \\ nil) do
    conn =
      case body do
        nil ->
          conn(method, path)

        body when is_binary(body) ->
          conn(method, path, body) |> put_req_header("content-type", "application/json")

        body ->
          conn(method, path, Jason.encode!(body))
          |> put_req_header("content-type", "application/json")
      end

    conn |> Router.call([]) |> decoded()
  end

  defp decoded(conn) do
    assert ["application/json; charset=utf-8"] = get_resp_header(conn, "content-type")
    {conn.status, Jason.decode!(conn.resp_body), conn}
  end

  defp create_author(attrs \\ %{}) do
    Ash.create!(Author, Map.merge(%{name: "Ada", profile: %{bio: "hi"}}, attrs))
  end

  defp create_post(author, attrs \\ %{}) do
    Ash.create!(Post, Map.merge(%{title: "Hello world", author_id: author.id}, attrs))
  end

  defp create_comment(post, attrs \\ %{}) do
    Ash.create!(Comment, Map.merge(%{body: "nice", post_id: post.id}, attrs))
  end

  describe "get" do
    test "returns a bare typed record with embedded, union, calculation and aggregate fields" do
      author = create_author()

      post =
        create_post(author, %{
          settings: %{color: "red"},
          content: %Ash.Union{type: :note, value: "n1"}
        })

      create_comment(post)

      {200, body, _} = request(:get, "/posts/#{post.id}")

      assert %{
               "id" => id,
               "type" => "post",
               "title" => "Hello world",
               "author_id" => author_id,
               "settings" => %{"color" => "red", "featured" => false},
               "content" => %{"note" => "n1"},
               "title_length" => 11,
               "comment_count" => 1,
               "published?" => false,
               "status" => "draft",
               "created_at" => created_at
             } = body

      assert id == post.id
      assert author_id == author.id
      assert is_binary(created_at)
      refute Map.has_key?(body, "inserted_at")
      refute Map.has_key?(body, "internal_notes")
      refute Map.has_key?(body, "author")
      refute Map.has_key?(body, "comments")
    end

    test "renders a typed-map union member" do
      post =
        create_post(create_author(), %{
          content: %Ash.Union{type: :link, value: %{url: "https://example.com"}}
        })

      {200, body, _} = request(:get, "/posts/#{post.id}")
      assert body["content"] == %{"link" => %{"url" => "https://example.com"}}
    end

    test "404 for a missing record" do
      {404, body, _} = request(:get, "/posts/#{Ash.UUID.generate()}")

      assert body == %{
               "error" => %{
                 "status" => 404,
                 "code" => "not_found",
                 "message" => "record not found"
               }
             }
    end

    test "nested includes type every record and only load what was asked" do
      author = create_author()
      post = create_post(author)
      create_comment(post, %{author_id: author.id})
      create_comment(post)

      {200, body, _} = request(:get, "/posts/#{post.id}?include=author,comments.author")

      assert %{"type" => "author", "name" => "Ada", "profile" => %{"bio" => "hi"}} =
               body["author"]

      assert length(body["comments"]) == 2

      for comment <- body["comments"] do
        assert comment["type"] == "comment"
        assert Map.has_key?(comment, "author")
      end

      assert Enum.any?(body["comments"], &match?(%{"author" => %{"type" => "author"}}, &1))
      assert Enum.any?(body["comments"], &match?(%{"author" => nil}, &1))

      {200, body, _} = request(:get, "/posts/#{post.id}?include=comments")
      refute Map.has_key?(body, "author")
      refute Map.has_key?(hd(body["comments"]), "author")
    end

    test "400 invalid_include outside the allow-list" do
      post = create_post(create_author())

      {400, body, _} = request(:get, "/posts/#{post.id}?include=comments.post")

      assert %{
               "error" => %{
                 "code" => "invalid_include",
                 "status" => 400,
                 "message" => "comments.post cannot be included",
                 "details" => [%{"field" => "include", "code" => "invalid_include"}]
               }
             } = body

      {400, %{"error" => %{"code" => "invalid_include"}}, _} =
        request(:get, "/posts/#{post.id}?include=nope")
    end

    test "list query params are not accepted on record routes" do
      post = create_post(create_author())

      {400, body, _} = request(:get, "/posts/#{post.id}?sort=title")

      assert %{"error" => %{"code" => "unsupported_query_parameter"}} = body
    end
  end

  describe "index" do
    test "unpaginated list wrapper" do
      author = create_author()
      create_post(author, %{title: "A"})
      create_post(author, %{title: "B"})

      {200, body, _} = request(:get, "/posts")

      assert Map.keys(body) == ["data"]
      assert body["data"] |> Enum.map(& &1["title"]) |> Enum.sort() == ["A", "B"]
      assert Enum.all?(body["data"], &(&1["type"] == "post"))
    end

    test "filter and sort use wire names, including field_names renames" do
      author = create_author()
      create_post(author, %{title: "A", score: 1})
      create_post(author, %{title: "B", score: 5})
      create_post(author, %{title: "C", score: 3})

      {200, body, _} = request(:get, "/posts?sort=-score")
      assert Enum.map(body["data"], & &1["title"]) == ["B", "C", "A"]

      {200, body, _} = request(:get, "/posts?filter[score][gte]=3&sort=title")
      assert Enum.map(body["data"], & &1["title"]) == ["B", "C"]

      {200, body, _} = request(:get, "/posts?filter[title]=A")
      assert Enum.map(body["data"], & &1["title"]) == ["A"]

      {200, body, _} =
        request(:get, "/posts?sort=-created_at&filter[created_at][gte]=2000-01-01T00:00:00Z")

      assert length(body["data"]) == 3

      {400, body, _} = request(:get, "/posts?sort=-inserted_at")

      assert %{
               "error" => %{
                 "code" => "unknown_field",
                 "details" => [%{"field" => "sort.inserted_at"}]
               }
             } = body

      {400, body, _} = request(:get, "/posts?filter[score][eq]=abc")

      assert %{
               "error" => %{
                 "code" => "invalid_filter_value",
                 "details" => [%{"field" => "filter.score.eq"}]
               }
             } = body
    end

    test "offset pagination" do
      author = create_author()
      for title <- ~w(A B C), do: create_post(author, %{title: title})

      {200, body, _} = request(:get, "/posts/offset?page[limit]=2&page[count]=true&sort=title")

      assert %{"has_more" => true, "count" => 3, "limit" => 2, "offset" => 0} = body
      assert Enum.map(body["data"], & &1["title"]) == ["A", "B"]
      refute Map.has_key?(body, "next_cursor")

      {200, body, _} = request(:get, "/posts/offset?page[limit]=2&page[offset]=2&sort=title")
      assert %{"has_more" => false, "limit" => 2, "offset" => 2} = body
      refute Map.has_key?(body, "count")
      assert Enum.map(body["data"], & &1["title"]) == ["C"]
    end

    test "keyset pagination follows next_cursor and prev_cursor" do
      author = create_author()
      for title <- ~w(A B C), do: create_post(author, %{title: title})

      {200, page1, _} = request(:get, "/posts/keyset?page[count]=true&sort=title")

      assert %{"has_more" => true, "count" => 3, "prev_cursor" => nil, "next_cursor" => next} =
               page1

      assert is_binary(next)
      assert Enum.map(page1["data"], & &1["title"]) == ["A", "B"]
      refute Map.has_key?(page1, "limit")

      {200, page2, _} = request(:get, "/posts/keyset?page[after]=#{next}&sort=title")
      assert %{"has_more" => false, "next_cursor" => nil, "prev_cursor" => prev} = page2
      assert is_binary(prev)
      assert Enum.map(page2["data"], & &1["title"]) == ["C"]

      {200, page1_again, _} = request(:get, "/posts/keyset?page[before]=#{prev}&sort=title")
      assert Enum.map(page1_again["data"], & &1["title"]) == ["A", "B"]
      assert page1_again["prev_cursor"] == nil
      assert is_binary(page1_again["next_cursor"])
    end

    test "400 invalid_pagination for bad page values and unknown keys" do
      {400, body, _} = request(:get, "/posts/offset?page[limit]=abc")

      assert %{
               "error" => %{
                 "code" => "invalid_pagination",
                 "details" => [%{"field" => "page.limit", "code" => "invalid_pagination"}]
               }
             } = body

      {400, %{"error" => %{"code" => "invalid_pagination"}}, _} =
        request(:get, "/posts/offset?page[count]=maybe")

      {400, %{"error" => %{"code" => "invalid_pagination"}}, _} =
        request(:get, "/posts/offset?page[size]=3")

      {400, %{"error" => %{"code" => "invalid_pagination"}}, _} =
        request(:get, "/posts/offset?page=3")
    end

    test "400 for unsupported query params and fields" do
      {400, body, _} = request(:get, "/posts?foo=1")

      assert %{
               "error" => %{
                 "code" => "unsupported_query_parameter",
                 "message" => "Unsupported query parameter: foo",
                 "details" => [%{"field" => "foo"}]
               }
             } = body

      {400, body, _} = request(:get, "/posts?fields=id,title")
      assert %{"error" => %{"code" => "unsupported_query_parameter", "message" => message}} = body
      assert message =~ "sparse fieldsets"
    end
  end

  describe "post / patch / delete" do
    test "post creates and returns 201 with the record" do
      author = create_author()

      {201, body, _} =
        request(:post, "/posts", %{
          title: "Created",
          author_id: author.id,
          settings: %{color: "blue"},
          content: %{note: "hey"}
        })

      assert %{"type" => "post", "title" => "Created", "settings" => %{"color" => "blue"}} = body
      assert body["content"] == %{"note" => "hey"}
      assert Ash.get!(Post, body["id"]).title == "Created"
    end

    test "validation errors are 400 with details" do
      {400, body, _} = request(:post, "/posts", %{})

      assert body == %{
               "error" => %{
                 "status" => 400,
                 "code" => "required",
                 "message" => "attribute title is required",
                 "details" => [
                   %{
                     "field" => "title",
                     "code" => "required",
                     "message" => "attribute title is required"
                   }
                 ]
               }
             }

      {400, body, _} = request(:post, "/posts", %{title: "x", bogus: 1})

      assert %{"error" => %{"code" => "unknown_input", "details" => [%{"field" => "bogus"}]}} =
               body
    end

    test "415 for a non-JSON body, 400 for invalid JSON or a non-object body" do
      conn =
        conn(:post, "/posts", "title=x")
        |> put_req_header("content-type", "application/x-www-form-urlencoded")
        |> Router.call([])

      {415, body, _} = decoded(conn)
      assert %{"error" => %{"code" => "unsupported_media_type", "status" => 415}} = body

      {400, body, _} = request(:post, "/posts", "{not json")
      assert %{"error" => %{"code" => "invalid_body"}} = body

      {400, body, _} = request(:post, "/posts", "[1,2]")
      assert %{"error" => %{"code" => "invalid_body"}} = body
    end

    test "patch updates by id, 404 for an unknown id" do
      post = create_post(create_author())

      {200, body, _} = request(:patch, "/posts/#{post.id}", %{title: "Renamed"})
      assert %{"type" => "post", "title" => "Renamed", "title_length" => 7} = body

      {404, body, _} = request(:patch, "/posts/#{Ash.UUID.generate()}", %{title: "x"})
      assert %{"error" => %{"code" => "not_found", "status" => 404}} = body
    end

    test "delete returns the deleted record" do
      post = create_post(create_author())

      {200, body, _} = request(:delete, "/posts/#{post.id}")
      assert %{"type" => "post", "id" => id, "title" => "Hello world"} = body
      assert id == post.id
      assert {:error, _} = Ash.get(Post, post.id)
    end
  end

  describe "related" do
    test "to-many with filter, sort, page and include" do
      author = create_author()
      post = create_post(author)
      other = create_post(author)
      create_comment(post, %{rating: 5, author_id: author.id})
      create_comment(post, %{rating: 1})
      create_comment(post, %{rating: 3})
      create_comment(other, %{rating: 9})

      {200, body, _} = request(:get, "/posts/#{post.id}/comments")
      assert Map.keys(body) == ["data"]
      assert length(body["data"]) == 3
      assert Enum.all?(body["data"], &(&1["type"] == "comment"))

      {200, body, _} =
        request(:get, "/posts/#{post.id}/comments?filter[rating][gt]=2&sort=-rating")

      assert Enum.map(body["data"], & &1["rating"]) == [5, 3]

      {200, body, _} =
        request(
          :get,
          "/posts/#{post.id}/comments?sort=-rating&page[limit]=2&page[count]=true&include=author"
        )

      assert %{"has_more" => true, "count" => 3, "limit" => 2, "offset" => 0} = body

      assert [
               %{"rating" => 5, "author" => %{"type" => "author"}},
               %{"rating" => 3, "author" => nil}
             ] = body["data"]
    end

    test "404 when the parent is missing, 400 for an include outside the relationship's subtree" do
      {404, %{"error" => %{"code" => "not_found"}}, _} =
        request(:get, "/posts/#{Ash.UUID.generate()}/comments")

      post = create_post(create_author())

      {400, %{"error" => %{"code" => "invalid_include"}}, _} =
        request(:get, "/posts/#{post.id}/comments?include=post")
    end
  end

  describe "generic routes" do
    test "update action with metadata renders the record with meta" do
      post = create_post(create_author())

      {200, body, _} = request(:post, "/posts/#{post.id}/publish", %{})

      assert %{
               "type" => "post",
               "status" => "published",
               "published?" => true,
               "meta" => %{"published_by" => "ash_rest"}
             } = body

      {404, _, _} = request(:post, "/posts/#{Ash.UUID.generate()}/publish", %{})
    end

    test "query_params feed the action input and the raw value is returned" do
      {200, body, _} = request(:get, "/posts/word_count?text=one%20two%20three")
      assert body == 3

      {400, body, _} = request(:get, "/posts/word_count")
      assert %{"error" => %{"code" => "required", "details" => [%{"field" => "text"}]}} = body
    end

    test "wrap_in_result? wraps typed maps, no-return actions answer success" do
      {200, body, _} = request(:post, "/posts/stats", %{})
      assert body == %{"result" => %{"total" => 42}}

      {200, body, _} = request(:post, "/posts/ping", %{})
      assert body == %{"success" => true}
    end
  end

  describe "routing and authorization" do
    test "404 no_route_found" do
      {404, body, _} = request(:get, "/nothing/here")

      assert body == %{
               "error" => %{
                 "status" => 404,
                 "code" => "no_route_found",
                 "message" => "No route found for GET /nothing/here"
               }
             }
    end

    test "403 without an actor, 200 with an admin actor" do
      {403, body, _} = request(:get, "/secrets")

      assert body == %{
               "error" => %{"status" => 403, "code" => "forbidden", "message" => "forbidden"}
             }

      {200, body, _} =
        conn(:get, "/secrets")
        |> Ash.PlugHelpers.set_actor(%{role: :admin})
        |> Router.call([])
        |> decoded()

      assert body == %{"data" => []}

      {403, _, _} = request(:post, "/secrets", %{value: "x"})
    end

    test "every routed request carries the oaskit operation id" do
      {200, _, conn} = request(:get, "/posts")
      assert conn.private.oaskit == %{operation_id: "post.index"}

      {404, _, conn} = request(:get, "/posts/#{Ash.UUID.generate()}")
      assert conn.private.oaskit == %{operation_id: "post.get"}
    end
  end

  describe "AshRest.Response and AshRest.Errors units" do
    test "include_nil_values? false drops nil keys, type is injected through children" do
      shape = %{
        resource: Post,
        type: "post",
        include_nil?: false,
        children: %{
          "author" => %{resource: Author, type: "author", include_nil?: true, children: %{}}
        }
      }

      assert AshRest.Response.typed(
               %{"id" => 1, "body" => nil, "author" => %{"id" => 2, "email" => nil}},
               shape
             ) ==
               %{
                 "id" => 1,
                 "type" => "post",
                 "author" => %{"id" => 2, "email" => nil, "type" => "author"}
               }

      assert AshRest.Response.typed([%{"id" => 1, "author" => nil}], shape) == [
               %{"id" => 1, "type" => "post"}
             ]
    end

    test "messages interpolate vars and fall back to the short message" do
      assert AshRest.Errors.message(%{
               "message" => "Unknown field %{field}",
               "vars" => %{"field" => "x"}
             }) ==
               "Unknown field x"

      assert AshRest.Errors.message(%{"message" => "", "short_message" => "Short", "type" => "t"}) ==
               "Short"

      assert AshRest.Errors.message(%{"message" => "keep %{missing}", "vars" => %{}}) ==
               "keep %{missing}"
    end

    test "status mapping" do
      assert AshRest.Errors.status_for("not_found") == 404
      assert AshRest.Errors.status_for("action_not_found") == 404
      assert AshRest.Errors.status_for("forbidden") == 403
      assert AshRest.Errors.status_for("forbidden_field") == 403
      assert AshRest.Errors.status_for("internal_error") == 500
      assert AshRest.Errors.status_for("unknown_error") == 500
      assert AshRest.Errors.status_for("required") == 400
    end
  end

  describe "AshRest.Params units" do
    test "indexed_lists turns integer-keyed maps into ordered lists at any depth" do
      assert AshRest.Params.indexed_lists(%{
               "or" => %{"1" => %{"b" => "2"}, "0" => %{"a" => "1"}, "10" => %{"c" => "3"}}
             }) == %{"or" => [%{"a" => "1"}, %{"b" => "2"}, %{"c" => "3"}]}

      assert AshRest.Params.indexed_lists(%{
               "and" => %{"0" => %{"or" => %{"0" => %{"x" => "1"}}}, "1" => %{"y" => "2"}}
             }) == %{"and" => [%{"or" => [%{"x" => "1"}]}, %{"y" => "2"}]}

      # not all keys are indexes: kept as a map (recursing into values)
      assert AshRest.Params.indexed_lists(%{"0" => "a", "x" => %{"1" => "b"}}) ==
               %{"0" => "a", "x" => ["b"]}

      # negative or non-integer keys are field names
      assert AshRest.Params.indexed_lists(%{"-1" => "a"}) == %{"-1" => "a"}
      assert AshRest.Params.indexed_lists(%{"1.5" => "a"}) == %{"1.5" => "a"}
      assert AshRest.Params.indexed_lists(%{}) == %{}
      assert AshRest.Params.indexed_lists("x") == "x"
    end

    test "parse applies indexed lists to filter, treats an empty sort as none, and honours paginate?" do
      assert {:ok, %{filter: %{"or" => [%{"a" => "1"}]}, sort: nil}} =
               AshRest.Params.parse(
                 %{"filter" => %{"or" => %{"0" => %{"a" => "1"}}}, "sort" => ""},
                 kind: :list
               )

      assert {:error, {"unsupported_query_parameter", _, [%{"field" => "page"}]}} =
               AshRest.Params.parse(%{"page" => %{"limit" => "1"}}, kind: :list, paginate?: false)

      assert {:ok, %{page: %{"limit" => 1}}} =
               AshRest.Params.parse(%{"page" => %{"limit" => "1"}}, kind: :list, paginate?: true)
    end
  end

  describe "AshRest.Errors units" do
    test "code maps the forbidden exception names of show_raised_errors? to forbidden" do
      assert AshRest.Errors.code(%{"type" => "policy"}) == "forbidden"
      assert AshRest.Errors.code(%{"type" => "must_pass_strict_check"}) == "forbidden"
      assert AshRest.Errors.code(%{"type" => "required"}) == "required"
      assert AshRest.Errors.code(%{}) == "unknown_error"
      assert AshRest.Errors.status_for("policy") == 403
    end

    test "no errors at all is a 500 internal_error" do
      conn = AshRest.Errors.send_rpc_errors(Plug.Test.conn(:get, "/"), [])
      assert conn.status == 500

      assert Jason.decode!(conn.resp_body) == %{
               "error" => %{
                 "status" => 500,
                 "code" => "internal_error",
                 "message" => "An error occurred"
               }
             }
    end

    test "strip_path removes the relationship envelope from error paths" do
      errors = [
        %{
          "type" => "unknown_field",
          "message" => "Unknown field nope",
          "path" => ["comments", "filter"],
          "fields" => ["nope"]
        },
        %{
          "type" => "unknown_field",
          "message" => "x",
          "path" => ["other", "filter"],
          "fields" => ["nope"]
        }
      ]

      conn =
        AshRest.Errors.send_rpc_errors(Plug.Test.conn(:get, "/"), errors,
          strip_path: ["comments"]
        )

      assert %{
               "error" => %{
                 "details" => [%{"field" => "filter.nope"}, %{"field" => "other.filter.nope"}]
               }
             } =
               Jason.decode!(conn.resp_body)
    end
  end
end
