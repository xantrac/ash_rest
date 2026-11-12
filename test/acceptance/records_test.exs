# SPDX-FileCopyrightText: 2026 ash_rest contributors
#
# SPDX-License-Identifier: MIT

defmodule AshRest.Acceptance.RecordsTest do
  @moduledoc false
  # get / post / patch / put / delete of single records, every response
  # validated against the OpenAPI document.
  use AshRest.AcceptanceCase, async: true

  describe "get" do
    test "a bare record with type, renamed fields, embedded and union values" do
      author = create_author()

      post =
        create_post(author, %{
          settings: %{color: "red"},
          content: %Ash.Union{type: :link, value: %{url: "https://ash-hq.org"}}
        })

      id = post.id
      author_id = author.id

      record =
        Router
        |> get("/posts/#{id}")
        |> assert_record(%{
          "id" => ^id,
          "type" => "post",
          "author_id" => ^author_id,
          "settings" => %{"color" => "red", "featured" => false},
          "content" => %{"link" => %{"url" => "https://ash-hq.org"}},
          "status" => "draft",
          "published?" => false,
          "title_length" => 11,
          "comment_count" => 0
        })

      assert is_binary(record["created_at"])
      refute Map.has_key?(record, "inserted_at")
      refute Map.has_key?(record, "internal_notes")
    end

    test "null embedded and union values" do
      post = create_post(create_author())

      Router
      |> get("/posts/#{post.id}")
      |> assert_record(%{"settings" => nil, "content" => nil, "body" => nil})
    end

    test "an embedded resource on another resource" do
      author = create_author(%{profile: %{bio: "Mathematician", website: "https://ada.dev"}})

      Router
      |> get("/authors/#{author.id}")
      |> assert_record(%{
        "type" => "author",
        "profile" => %{"bio" => "Mathematician", "website" => "https://ada.dev"}
      })
    end

    test "include nests to-one and to-many relationships, typed at every level" do
      author = create_author()
      post = create_post(author)
      create_comment(post, %{author_id: author.id, rating: 4})

      record =
        Router
        |> get("/posts/#{post.id}?include=author,comments.author")
        |> assert_record(%{
          "author" => %{"type" => "author", "name" => "Ada"},
          "comments" => [
            %{"type" => "comment", "rating" => 4, "author" => %{"type" => "author"}}
          ]
        })

      refute Map.has_key?(record["author"], "posts")
    end

    test "404 for an unknown id and for an id that is not a UUID" do
      Router
      |> get("/posts/#{Ash.UUID.generate()}", status: 404)
      |> assert_error(404, "not_found")

      Router
      |> get("/posts/not-a-uuid", status: 404)
      |> assert_error(404, "not_found")
    end

    test "400 for an include outside the allow-list or a list parameter" do
      post = create_post(create_author())

      Router
      |> get("/posts/#{post.id}?include=comments.post", status: 400)
      |> assert_error_detail("include", "invalid_include")

      Router
      |> get("/posts/#{post.id}?page[limit]=1", status: 400)
      |> assert_error_detail("page", "unsupported_query_parameter")
    end
  end

  describe "post" do
    test "201 with the created record, embedded and union input" do
      author = create_author()

      conn =
        post(Router, "/posts", %{
          title: "Created",
          author_id: author.id,
          settings: %{featured: true},
          content: %{link: %{url: "https://example.com"}}
        })

      record =
        assert_record(conn, %{
          "type" => "post",
          "title" => "Created",
          "settings" => %{"featured" => true, "color" => nil},
          "content" => %{"link" => %{"url" => "https://example.com"}}
        })

      assert Ash.get!(Post, record["id"]).settings.featured

      Router
      |> post("/posts", %{title: "Note", author_id: author.id, content: %{note: "n"}})
      |> assert_record(%{"content" => %{"note" => "n"}})
    end

    test "include on a create" do
      author = create_author()

      Router
      |> post("/posts?include=author", %{title: "With author", author_id: author.id})
      |> assert_record(%{"author" => %{"type" => "author", "name" => "Ada"}})
    end

    test "400 required, with every error in details" do
      conn = post(Router, "/posts", %{body: 1}, status: 400)

      assert_error(conn, 400, "invalid_attribute")
      assert_error_detail(conn, "body", "invalid_attribute")
      assert_error_detail(conn, "title", "required")
    end

    test "400 unknown_input for top-level and nested unknown keys" do
      Router
      |> post("/posts", %{title: "x", bogus: 1}, status: 400)
      |> assert_error_detail("bogus", "unknown_input")

      Router
      |> post("/posts", %{title: "x", settings: %{bogus: 1}}, status: 400)
      |> assert_error_detail("settings.bogus", "unknown_input")
    end

    test "400 for invalid embedded and union input" do
      Router
      |> post("/posts", %{title: "x", settings: %{featured: "maybe"}}, status: 400)
      |> assert_error_detail("settings.featured", "invalid_attribute")

      Router
      |> post("/posts", %{title: "x", content: %{link: %{}}}, status: 400)
      |> assert_error_detail("content", "invalid_attribute")

      Router
      |> post("/posts", %{title: "x", content: %{nope: 1}}, status: 400)
      |> assert_error(400, "invalid_union_input")
    end

    test "internal names of renamed fields are unknown input" do
      Router
      |> post("/notes", %{title: "x", body: "internal name"}, status: 400)
      |> assert_error_detail("body", "unknown_input")

      Router
      |> post("/notes", %{title: "x", text: "wire name", pinned: true})
      |> assert_record(%{"text" => "wire name", "pinned" => true})
    end
  end

  describe "patch" do
    test "updates by id and accepts include" do
      post = create_post(create_author())

      Router
      |> patch("/posts/#{post.id}?include=author", %{title: "Renamed"})
      |> assert_record(%{
        "title" => "Renamed",
        "title_length" => 7,
        "author" => %{"name" => "Ada"}
      })
    end

    test "404 for an unknown id, 400 for unknown input" do
      Router
      |> patch("/posts/#{Ash.UUID.generate()}", %{title: "x"}, status: 404)
      |> assert_error(404, "not_found")

      post = create_post(create_author())

      Router
      |> patch("/posts/#{post.id}", %{nope: 1}, status: 400)
      |> assert_error_detail("nope", "unknown_input")
    end

    test "read_action scopes which records can be updated" do
      unpinned = create_note(%{title: "Loose"})
      pinned = create_note(%{title: "Pinned", pinned?: true})

      Router
      |> patch("/notes/#{unpinned.id}/pinned", %{title: "x"}, status: 404)
      |> assert_error(404, "not_found")

      Router
      |> patch("/notes/#{pinned.id}/pinned", %{title: "Still pinned"})
      |> assert_record(%{"title" => "Still pinned", "pinned" => true})
    end

    test "an empty body updates nothing" do
      note = create_note(%{title: "Same"})

      Router
      |> patch("/notes/#{note.id}", nil)
      |> assert_record(%{"title" => "Same"})
    end
  end

  describe "put (route to an update action)" do
    test "updates by id" do
      note = create_note()

      Router
      |> put("/notes/#{note.id}", %{title: "Put"})
      |> assert_record(%{"title" => "Put", "type" => "note"})

      Router
      |> put("/notes/#{Ash.UUID.generate()}", %{title: "Put"}, status: 404)
      |> assert_error(404, "not_found")
    end
  end

  describe "delete" do
    test "responds with the deleted record" do
      note = create_note(%{title: "Bye"})
      id = note.id

      Router
      |> delete("/notes/#{id}")
      |> assert_record(%{"id" => ^id, "title" => "Bye"})

      assert {:error, _} = Ash.get(Note, id)

      Router
      |> delete("/notes/#{id}", status: 404)
      |> assert_error(404, "not_found")
    end

    # An atomic destroy cannot load aggregates after the row is gone, so the
    # deleted record has no `comment_count`; the schema does not require it.
    test "a deleted post matches the Post schema" do
      post = create_post(create_author())

      record =
        Router
        |> delete("/posts/#{post.id}")
        |> assert_record(%{"type" => "post"})

      refute Map.has_key?(record, "comment_count")
    end
  end

  describe "include_nil_values? false" do
    test "drops null keys from records and lists" do
      note = create_note(%{title: "Sparse"})

      record =
        Router
        |> get("/notes/#{note.id}")
        |> assert_record(%{"title" => "Sparse", "pinned" => false, "type" => "note"})

      refute Map.has_key?(record, "text")
      refute Map.has_key?(record, "priority")

      Router
      |> post("/notes", %{title: "Full", text: "t", priority: 1})
      |> assert_record(%{"text" => "t", "priority" => 1})

      Router
      |> get("/notes/paged?sort=title")
      |> assert_list([%{"title" => "Full", "text" => "t"}, sparse])

      refute Map.has_key?(sparse, "text")
    end
  end
end
