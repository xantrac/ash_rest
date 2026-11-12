# SPDX-FileCopyrightText: 2026 ash_rest contributors
#
# SPDX-License-Identifier: MIT

defmodule AshRest.Acceptance.ListsTest do
  @moduledoc false
  # index routes: filter, sort, offset and keyset pagination, count, include.
  # Every response is validated against the OpenAPI document.
  use AshRest.AcceptanceCase, async: true

  defp seed_posts do
    author = create_author()
    other = create_author(%{name: "Grace"})
    a = create_post(author, %{title: "A", score: 1, body: "alpha"})
    b = create_post(other, %{title: "B", score: 5, status: :published})
    c = create_post(author, %{title: "C", score: 3})
    create_comment(a)
    create_comment(a)
    %{author: author, other: other, a: a, b: b, c: c}
  end

  describe "unpaginated" do
    test "a data-only wrapper of typed records" do
      seed_posts()

      conn = get(Router, "/posts?sort=title")
      assert Map.keys(json(conn)) == ["data"]

      assert_list(conn, [
        %{"title" => "A", "type" => "post", "comment_count" => 2},
        %{"title" => "B", "type" => "post"},
        %{"title" => "C", "type" => "post"}
      ])
    end

    test "an empty list" do
      Router |> get("/posts") |> assert_list(%{"data" => []})
    end

    test "include on every record" do
      seed_posts()

      [first | _] =
        Router
        |> get("/posts?sort=title&include=author,comments")
        |> assert_list(3)

      assert %{"author" => %{"type" => "author", "name" => "Ada"}, "comments" => [_, _]} = first
    end
  end

  describe "filter" do
    setup do
      seed_posts()
    end

    test "bare values, operators, and their short forms" do
      assert Router |> get("/posts?filter[title]=B") |> titles() == ["B"]
      assert Router |> get("/posts?filter[score][eq]=3") |> titles() == ["C"]
      assert Router |> get("/posts?filter[score][not_eq]=3&sort=title") |> titles() == ["A", "B"]
      assert Router |> get("/posts?filter[score][gt]=1&sort=title") |> titles() == ["B", "C"]

      assert Router |> get("/posts?filter[score][greater_than]=1&sort=title") |> titles() ==
               ["B", "C"]

      assert Router |> get("/posts?filter[score][gte]=3&sort=title") |> titles() == ["B", "C"]
      assert Router |> get("/posts?filter[score][lt]=3") |> titles() == ["A"]

      assert Router |> get("/posts?filter[score][less_than_or_equal]=3&sort=title") |> titles() ==
               ["A", "C"]

      assert Router
             |> get("/posts?filter[title][in][]=A&filter[title][in][]=C&sort=title")
             |> titles() == ["A", "C"]

      assert Router |> get("/posts?filter[body][is_nil]=false") |> titles() == ["A"]
      assert Router |> get("/posts?filter[title][contains]=B") |> titles() == ["B"]
      assert Router |> get("/posts?filter[status]=published") |> titles() == ["B"]
    end

    test "several fields, not, relationships, calculations and aggregates" do
      assert Router |> get("/posts?filter[score][gte]=3&filter[status]=draft") |> titles() ==
               ["C"]

      assert Router |> get("/posts?filter[not][title]=B&sort=title") |> titles() == ["A", "C"]
      assert Router |> get("/posts?filter[author][name]=Grace") |> titles() == ["B"]
      assert Router |> get("/posts?filter[comment_count][gt]=0") |> titles() == ["A"]

      assert Router |> get("/posts?filter[title_length][eq]=1&sort=-title") |> titles() ==
               ["C", "B", "A"]
    end

    test "renamed fields filter by their wire name only" do
      assert Router
             |> get("/posts?filter[created_at][gte]=2000-01-01T00:00:00Z&sort=title")
             |> titles() == ["A", "B", "C"]

      Router
      |> get("/posts?filter[inserted_at][gte]=2000-01-01T00:00:00Z", status: 400)
      |> assert_error_detail("filter.inserted_at", "unknown_field")

      create_note(%{title: "N", body: "findme"})
      assert Router |> get("/notes?filter[text]=findme") |> titles() == ["N"]
    end

    test "400 for unknown fields, operators and uncastable values" do
      Router
      |> get("/posts?filter[nope]=1", status: 400)
      |> assert_error_detail("filter.nope", "unknown_field")

      Router
      |> get("/posts?filter[title][like]=x", status: 400)
      |> assert_error_detail("filter.title.like", "unknown_filter_operator")

      Router
      |> get("/posts?filter[score][eq]=abc", status: 400)
      |> assert_error_detail("filter.score.eq", "invalid_filter_value")

      Router
      |> get("/posts?filter[title][in]=A,B", status: 400)
      |> assert_error_detail("filter.title.in", "invalid_filter_value")

      Router
      |> get("/posts?filter=title", status: 400)
      |> assert_error_detail("filter", "invalid_filter")
    end

    # `or`/`and` take a list of filters, written with indexes: Plug decodes
    # `filter[or][0][title]=A&filter[or][1][score]=5` into a map keyed "0"/"1",
    # which AshRest.Params turns into a list (`filter[or][][...]` cannot be
    # disambiguated by Plug and is not supported).
    test "or and and with indexed filters, at any depth" do
      assert Router
             |> get("/posts?filter[or][0][title]=A&filter[or][1][score]=5&sort=title")
             |> titles() == ["A", "B"]

      assert Router
             |> get(
               "/posts?filter[and][0][score][gte]=3&filter[and][1][or][0][title]=B&filter[and][1][or][1][title]=C&sort=title"
             )
             |> titles() == ["B", "C"]

      # a non-index key keeps the map as a field filter
      Router
      |> get("/posts?filter[or][0][title]=A&filter[or][x][title]=B", status: 400)
      |> assert_error(400, "unknown_field")
    end

    test "enable_filter? false rejects filter on index routes" do
      Router
      |> get("/notes/unfiltered?filter[title]=x", status: 400)
      |> assert_error(400, "filter_not_supported")

      Router
      |> get("/notes/unfiltered?sort=title", status: 400)
      |> assert_error(400, "sort_not_supported")
    end
  end

  describe "sort" do
    setup do
      seed_posts()
    end

    test "ascending, descending, several fields, calculations and aggregates" do
      assert Router |> get("/posts?sort=-score") |> titles() == ["B", "C", "A"]
      assert Router |> get("/posts?sort=-comment_count,title") |> titles() == ["A", "B", "C"]
      assert Router |> get("/posts?sort=title_length,-title") |> titles() == ["C", "B", "A"]
      assert Router |> get("/posts?sort=-created_at") |> titles() == ["C", "B", "A"]
    end

    test "renamed fields sort by their wire name only" do
      create_note(%{title: "x", body: "b"})
      create_note(%{title: "y", body: "a"})
      assert Router |> get("/notes?sort=text") |> titles() == ["y", "x"]

      Router
      |> get("/posts?sort=-inserted_at", status: 400)
      |> assert_error_detail("sort.inserted_at", "unknown_field")
    end

    test "an empty sort means no sort" do
      assert Router |> get("/posts?sort=") |> titles() |> Enum.sort() == ["A", "B", "C"]
      assert Router |> get("/posts?sort=&filter[title]=A") |> titles() == ["A"]
    end

    test "400 for relationship paths and non-string sorts" do
      Router
      |> get("/posts?sort=author.name", status: 400)
      |> assert_error_detail("sort.author.name", "unknown_field")

      Router
      |> get("/posts?sort[]=title", status: 400)
      |> assert_error_detail("sort", "invalid_sort")
    end
  end

  describe "offset pagination" do
    setup do
      seed_posts()
    end

    test "limit, offset, count and has_more" do
      conn = get(Router, "/posts/offset?page[limit]=2&page[count]=true&sort=title")

      assert_list(conn, %{"has_more" => true, "count" => 3, "limit" => 2, "offset" => 0})
      assert titles(conn) == ["A", "B"]
      refute Map.has_key?(json(conn), "next_cursor")

      conn = get(Router, "/posts/offset?page[limit]=2&page[offset]=2&sort=title")
      assert_list(conn, %{"has_more" => false, "limit" => 2, "offset" => 2})
      assert titles(conn) == ["C"]
      refute Map.has_key?(json(conn), "count")
    end

    test "the action's default_limit applies when only count is given" do
      Router
      |> get("/posts/offset?page[count]=true&sort=title")
      |> assert_list(%{"count" => 3, "limit" => 2, "data" => [_, _]})
    end

    test "an optional paginated action is unpaginated without page" do
      conn = get(Router, "/posts/offset")
      assert Map.keys(json(conn)) == ["data"]
      assert_list(conn, 3)
    end

    test "an offset past the end is an empty page" do
      Router
      |> get("/posts/offset?page[offset]=10")
      |> assert_list(%{"data" => [], "has_more" => false, "offset" => 10})
    end

    test "400 invalid_pagination for malformed values and unknown keys" do
      Router
      |> get("/posts/offset?page[limit]=abc", status: 400)
      |> assert_error_detail("page.limit", "invalid_pagination")

      Router
      |> get("/posts/offset?page[offset]=-1", status: 400)
      |> assert_error_detail("page.offset", "invalid_pagination")

      Router
      |> get("/posts/offset?page[count]=maybe", status: 400)
      |> assert_error_detail("page.count", "invalid_pagination")

      Router
      |> get("/posts/offset?page[size]=3", status: 400)
      |> assert_error_detail("page.size", "invalid_pagination")

      Router
      |> get("/posts/offset?page=3", status: 400)
      |> assert_error_detail("page", "invalid_pagination")
    end

    # `paginate?: false`: `page` is rejected like any parameter the route does
    # not take, and the read runs unpaginated.
    test "paginate? false does not paginate" do
      for title <- ~w(x y z), do: create_note(%{title: title})

      conn = get(Router, "/notes/paged?page[limit]=1", status: 400)
      assert_error_detail(conn, "page", "unsupported_query_parameter")

      conn = get(Router, "/notes/paged?sort=title")
      assert Map.keys(json(conn)) == ["data"]
      assert titles(conn) == ["x", "y", "z"]
    end
  end

  describe "keyset pagination" do
    setup do
      for title <- ~w(A B C D E), do: create_post(create_author(), %{title: title})
      :ok
    end

    test "following next_cursor forward and prev_cursor back" do
      page1 = get(Router, "/posts/keyset?page[count]=true&sort=title")
      assert titles(page1) == ["A", "B"]

      assert %{"has_more" => true, "count" => 5, "prev_cursor" => nil, "next_cursor" => next1} =
               json(page1)

      refute Map.has_key?(json(page1), "limit")

      page2 = get(Router, "/posts/keyset?sort=title&page[after]=#{next1}")
      assert titles(page2) == ["C", "D"]
      assert %{"has_more" => true, "next_cursor" => next2, "prev_cursor" => prev2} = json(page2)
      assert is_binary(next2) and is_binary(prev2)

      page3 = get(Router, "/posts/keyset?sort=title&page[after]=#{next2}")
      assert titles(page3) == ["E"]
      assert %{"has_more" => false, "next_cursor" => nil, "prev_cursor" => prev3} = json(page3)

      # backwards from the last page: has_more says whether more records come before
      back2 = get(Router, "/posts/keyset?sort=title&page[before]=#{prev3}")
      assert titles(back2) == ["C", "D"]

      assert %{"has_more" => true, "prev_cursor" => prev_back, "next_cursor" => next_back} =
               json(back2)

      assert is_binary(prev_back) and is_binary(next_back)

      back1 = get(Router, "/posts/keyset?sort=title&page[before]=#{prev_back}")
      assert titles(back1) == ["A", "B"]

      assert %{"has_more" => false, "prev_cursor" => nil, "next_cursor" => next_again} =
               json(back1)

      assert Router |> get("/posts/keyset?sort=title&page[after]=#{next_again}") |> titles() ==
               ["C", "D"]
    end

    test "limit and descending sort" do
      conn = get(Router, "/posts/keyset?page[limit]=3&sort=-title")
      assert titles(conn) == ["E", "D", "C"]

      %{"next_cursor" => next} = json(conn)

      assert Router
             |> get("/posts/keyset?page[limit]=3&sort=-title&page[after]=#{next}")
             |> titles() == ["B", "A"]
    end

    test "an empty page has no cursors" do
      Router
      |> get("/posts/keyset?page[limit]=2&filter[title]=nope")
      |> assert_list(%{
        "data" => [],
        "has_more" => false,
        "next_cursor" => nil,
        "prev_cursor" => nil
      })
    end

    test "400 for a cursor that cannot be decoded or an empty one" do
      Router
      |> get("/posts/keyset?page[after]=garbage", status: 400)
      |> assert_error(400, "invalid_keyset")

      Router
      |> get("/posts/keyset?page[before]=", status: 400)
      |> assert_error_detail("page.before", "invalid_pagination")
    end

    test "an action with both styles uses offset unless a cursor is given" do
      Router
      |> get("/posts?page[limit]=2&sort=title")
      |> assert_list(%{"limit" => 2, "offset" => 0, "has_more" => true})
    end
  end

  describe "query parameters" do
    test "400 for unsupported parameters and sparse fieldsets" do
      Router
      |> get("/posts?foo=1", status: 400)
      |> assert_error_detail("foo", "unsupported_query_parameter")

      error =
        Router
        |> get("/posts?fields=title", status: 400)
        |> assert_error(400, "unsupported_query_parameter")

      assert error["message"] =~ "sparse fieldsets"
    end

    test "400 for an include outside the allow-list" do
      Router
      |> get("/posts?include=comments.post", status: 400)
      |> assert_error_detail("include", "invalid_include")
    end
  end
end
