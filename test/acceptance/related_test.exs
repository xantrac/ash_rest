# SPDX-FileCopyrightText: 2026 ash_rest contributors
#
# SPDX-License-Identifier: MIT

defmodule AshRest.Acceptance.RelatedTest do
  @moduledoc false
  # `related` routes, to-many and to-one. The route's action is a read action
  # on the source resource; the related records are loaded through it.
  use AshRest.AcceptanceCase, async: true

  describe "to-many" do
    setup do
      author = create_author()
      post = create_post(author)
      other = create_post(author, %{title: "Other"})
      create_comment(post, %{rating: 5, author_id: author.id, body: "five"})
      create_comment(post, %{rating: 1, body: "one"})
      create_comment(post, %{rating: 3, body: "three"})
      create_comment(other, %{rating: 9})
      %{author: author, post: post}
    end

    test "only the parent's records, unpaginated without page", %{post: post} do
      conn = get(Router, "/posts/#{post.id}/comments")

      assert Map.keys(json(conn)) == ["data"]
      records = assert_list(conn, 3)
      assert Enum.all?(records, &(&1["type"] == "comment" and &1["post_id"] == post.id))
    end

    test "filter and sort", %{post: post} do
      conn = get(Router, "/posts/#{post.id}/comments?filter[rating][gt]=2&sort=-rating")
      assert_list(conn, [%{"rating" => 5}, %{"rating" => 3}])

      conn = get(Router, "/posts/#{post.id}/comments?filter[body][contains]=e&sort=rating")
      assert_list(conn, [%{"body" => "one"}, %{"body" => "three"}, %{"body" => "five"}])
    end

    test "offset pages with count, and include of the related records", %{post: post} do
      conn =
        get(
          Router,
          "/posts/#{post.id}/comments?sort=-rating&page[limit]=2&page[count]=true&include=author"
        )

      assert_list(conn, %{"has_more" => true, "count" => 3, "limit" => 2, "offset" => 0})

      assert_list(conn, [
        %{"rating" => 5, "author" => %{"type" => "author", "name" => "Ada"}},
        %{"rating" => 3, "author" => nil}
      ])

      conn = get(Router, "/posts/#{post.id}/comments?sort=-rating&page[limit]=2&page[offset]=2")
      assert_list(conn, %{"has_more" => false, "offset" => 2, "data" => [%{"rating" => 1}]})
    end

    test "has_many on another resource", %{author: author} do
      conn = get(Router, "/authors/#{author.id}/posts?sort=title")
      assert_list(conn, [%{"title" => "Hello world"}, %{"title" => "Other"}])
    end

    test "404 for a missing parent", %{post: _post} do
      Router
      |> get("/posts/#{Ash.UUID.generate()}/comments", status: 404)
      |> assert_error(404, "not_found")
    end

    test "include is limited to the relationship's subtree", %{post: post} do
      Router
      |> get("/posts/#{post.id}/comments?include=post", status: 400)
      |> assert_error_detail("include", "invalid_include")
    end

    test "400 for bad filter, sort and page values", %{post: post} do
      Router
      |> get("/posts/#{post.id}/comments?filter[nope]=1", status: 400)
      |> assert_error(400, "unknown_field")

      Router
      |> get("/posts/#{post.id}/comments?sort=nope", status: 400)
      |> assert_error(400, "unknown_field")

      Router
      |> get("/posts/#{post.id}/comments?page[limit]=x", status: 400)
      |> assert_error_detail("page.limit", "invalid_pagination")
    end

    # Errors raised inside the relationship envelope ash_rpc runs the related
    # read through name the query parameter the client sent, not the envelope.
    test "error details of a related route point at the query parameter", %{post: post} do
      Router
      |> get("/posts/#{post.id}/comments?filter[nope]=1", status: 400)
      |> assert_error_detail("filter.nope", "unknown_field")

      Router
      |> get("/posts/#{post.id}/comments?sort=nope", status: 400)
      |> assert_error_detail("sort.nope", "unknown_field")
    end

    # Same error as an `index` route with the flags off.
    test "enable_filter? false and enable_sort? false on a related route", %{author: author} do
      Router
      |> get("/authors/#{author.id}/posts_unfiltered?filter[title]=zzz", status: 400)
      |> assert_error(400, "filter_not_supported")
      |> then(&refute(Map.has_key?(&1, "details")))

      Router
      |> get("/authors/#{author.id}/posts_unfiltered?sort=title", status: 400)
      |> assert_error(400, "sort_not_supported")

      Router
      |> get("/authors/#{author.id}/posts_unfiltered?page[limit]=1")
      |> assert_list(%{"has_more" => true, "limit" => 1})
    end

    # The relationship's read action (Comment's default read) paginates both
    # ways, so cursors work like on an index route.
    test "keyset cursors on a related route", %{post: post} do
      page1 = get(Router, "/posts/#{post.id}/comments?sort=rating&page[limit]=1&page[count]=true")
      assert_list(page1, [%{"rating" => 1}])

      # page[after] with a cursor of the first record: the related read is a
      # keyset page with cursors of its own
      cursor = keyset_cursor(post, 1)

      page2 =
        get(
          Router,
          "/posts/#{post.id}/comments?sort=rating&page[limit]=1&page[count]=true&page[after]=#{cursor}"
        )

      assert_list(page2, [%{"rating" => 3}])

      assert %{"has_more" => true, "count" => 3, "next_cursor" => next, "prev_cursor" => prev} =
               json(page2)

      assert is_binary(next) and is_binary(prev)
      refute Map.has_key?(json(page2), "limit")

      page3 =
        get(Router, "/posts/#{post.id}/comments?sort=rating&page[limit]=1&page[after]=#{next}")

      assert_list(page3, %{
        "has_more" => false,
        "next_cursor" => nil,
        "data" => [%{"rating" => 5}]
      })

      back =
        get(Router, "/posts/#{post.id}/comments?sort=rating&page[limit]=1&page[before]=#{prev}")

      assert_list(back, %{"has_more" => false, "prev_cursor" => nil, "data" => [%{"rating" => 1}]})

      Router
      |> get("/posts/#{post.id}/comments?sort=rating&page[limit]=1&page[after]=nope", status: 400)
      |> assert_error(400, "invalid_keyset")
    end

    test "a page without a limit uses the action's default_limit, else its max_page_size",
         %{post: post} do
      # Comment's default read has no default_limit; Ash's default max_page_size is 250
      conn = get(Router, "/posts/#{post.id}/comments?page[count]=true")
      assert_list(conn, %{"count" => 3, "limit" => 250, "offset" => 0, "has_more" => false})

      conn =
        get(
          Router,
          "/posts/#{post.id}/comments?sort=rating&page[after]=#{keyset_cursor(post, 1)}"
        )

      assert_list(conn, %{"has_more" => false, "next_cursor" => nil, "data" => [_, _]})
    end
  end

  # The keyset cursor Ash gives a comment of `post` with `rating`, sorted by rating.
  defp keyset_cursor(post, rating) do
    %{results: [comment]} =
      Comment
      |> Ash.Query.filter_input(%{post_id: post.id, rating: rating})
      |> Ash.Query.sort(:rating)
      |> Ash.read!(page: [limit: 1])

    comment.__metadata__.keyset
  end

  describe "to-one" do
    setup do
      author = create_author()
      post = create_post(author)
      with_author = create_comment(post, %{author_id: author.id})
      anonymous = create_comment(post)
      %{author: author, with_author: with_author, anonymous: anonymous}
    end

    test "the related record", %{author: author, with_author: comment} do
      author_id = author.id

      Router
      |> get("/comments/#{comment.id}/author")
      |> assert_record(%{
        "id" => ^author_id,
        "type" => "author",
        "name" => "Ada",
        "profile" => %{"bio" => "hi"}
      })
    end

    test "null when there is none", %{anonymous: comment} do
      conn = get(Router, "/comments/#{comment.id}/author")
      assert conn.resp_body == "null"
      assert json(conn) == nil
    end

    test "404 for a missing parent" do
      Router
      |> get("/comments/#{Ash.UUID.generate()}/author", status: 404)
      |> assert_error(404, "not_found")
    end

    test "list parameters are rejected, include outside the subtree too", %{
      with_author: comment
    } do
      Router
      |> get("/comments/#{comment.id}/author?sort=name", status: 400)
      |> assert_error_detail("sort", "unsupported_query_parameter")

      Router
      |> get("/comments/#{comment.id}/author?include=posts", status: 400)
      |> assert_error_detail("include", "invalid_include")
    end
  end
end
