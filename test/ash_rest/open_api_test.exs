# SPDX-FileCopyrightText: 2026 ash_rest contributors
#
# SPDX-License-Identifier: MIT

defmodule AshRest.OpenApiTest do
  use ExUnit.Case, async: true

  import Plug.Conn

  alias AshRest.TestApp.Router

  @json "application/json"
  @uuid "0d3b5f6a-3c2e-4a1b-9f0e-1234567890ab"

  setup_all do
    %{spec: AshRest.OpenApi.spec(Router)}
  end

  defp operation(spec, path, method), do: spec["paths"][path][method]

  defp schema_of(spec, name), do: spec["components"]["schemas"][name]

  defp response_schema(spec, path, method, status) do
    operation(spec, path, method)["responses"][status]["content"][@json]["schema"]
  end

  defp parameter(spec, path, method, name) do
    Enum.find(operation(spec, path, method)["parameters"], &(&1["name"] == name))
  end

  defp parameter_names(spec, path, method) do
    Enum.map(operation(spec, path, method)["parameters"], & &1["name"])
  end

  defp error_ref(name), do: %{"$ref" => "#/components/responses/#{name}"}

  # Validates `data` against `schema` in the context of the whole document, so
  # `$ref`s into `#/components/schemas` resolve.
  defp valid?(spec, schema, data) do
    root = JSV.build!(Map.merge(spec, schema), Oaskit.default_jsv_opts())

    case JSV.validate(data, root) do
      {:ok, _} -> true
      {:error, _} -> false
    end
  end

  defp post_record do
    %{
      "id" => @uuid,
      "type" => "post",
      "title" => "Hello",
      "body" => nil,
      "status" => "draft",
      "score" => 0,
      "published?" => false,
      "settings" => %{"featured" => true, "color" => nil},
      "content" => %{"link" => %{"url" => "https://example.com"}},
      "title_length" => 5,
      "comment_count" => 0,
      "author_id" => @uuid,
      "created_at" => "2026-01-01T12:00:00.000000Z"
    }
  end

  defp note_record,
    do: %{"id" => @uuid, "type" => "note", "title" => "Sparse", "pinned?" => false}

  describe "document" do
    test "is OpenAPI 3.1 with the router's info overrides", %{spec: spec} do
      assert spec["openapi"] == "3.1.0"
      assert spec["info"] == %{"title" => "AshRest test API", "version" => "1.0.0"}
    end

    test "validates against the OpenAPI 3.1 meta-schema", %{spec: spec} do
      assert %Oaskit.Spec.OpenAPI{} =
               spec |> Oaskit.normalize_spec!() |> Oaskit.SpecValidator.validate!()
    end

    test "has one operation per route, named after the route", %{spec: spec} do
      routes = AshRest.Manifest.routes(Router)
      assert routes != []

      for {_domain, resource, route} <- routes do
        path = String.replace(route.route, ~r/:(\w+)/, "{\\1}")
        op = operation(spec, path, Atom.to_string(route.method))
        assert op, "missing operation for #{route.method} #{path}"
        assert op["operationId"] == route.name
        assert op["tags"] == (route.tags || [AshRest.Resource.Info.open_api_tag(resource)])
        assert Map.has_key?(op["responses"], "400")
        assert Map.has_key?(op["responses"], "403")
        assert Map.has_key?(op["responses"], "500")
      end
    end

    test "every operation with a body declares 400, 413 and 415; others do not", %{spec: spec} do
      for {_domain, _resource, route} <- AshRest.Manifest.routes(Router) do
        path = String.replace(route.route, ~r/:(\w+)/, "{\\1}")
        responses = operation(spec, path, Atom.to_string(route.method))["responses"]

        if route.method in [:post, :patch, :put] do
          assert responses["400"] == error_ref("BadRequest"), route.name
          assert responses["413"] == error_ref("PayloadTooLarge"), route.name
          assert responses["415"] == error_ref("UnsupportedMediaType"), route.name
        else
          refute Map.has_key?(responses, "413"), route.name
          refute Map.has_key?(responses, "415"), route.name
        end
      end

      # Routes without a requestBody included: the runtime still rejects
      # non-JSON and oversized bodies.
      ping = operation(spec, "/posts/ping", "post")
      refute Map.has_key?(ping, "requestBody")
      assert ping["responses"]["413"] == error_ref("PayloadTooLarge")
      assert ping["responses"]["415"] == error_ref("UnsupportedMediaType")
    end

    test "the router's spec module builds and dumps with oaskit" do
      {built, _jsv_root} = Oaskit.build_spec!(Router.OpenApi, responses: true, cache: false)

      for {_d, _r, route} <- AshRest.Manifest.routes(Router) do
        assert Map.has_key?(built, route.name)
      end

      json = Oaskit.to_json!(Router.OpenApi)
      assert %{"openapi" => "3.1.0", "paths" => %{"/posts" => _}} = Jason.decode!(json)
    end

    test "has error components", %{spec: spec} do
      assert %{"required" => ["error"]} = schema_of(spec, "Error")
      assert %{"required" => ["code", "message"]} = detail = schema_of(spec, "ErrorDetail")
      assert detail["properties"]["field"]["type"] == ["string", "null"]

      for name <-
            ~w(BadRequest Forbidden NotFound PayloadTooLarge UnsupportedMediaType InternalServerError) do
        assert %{
                 "content" => %{@json => %{"schema" => %{"$ref" => "#/components/schemas/Error"}}}
               } =
                 spec["components"]["responses"][name]
      end
    end
  end

  describe "include" do
    test "is accepted by every route that returns records of a resource with includes", %{
      spec: spec
    } do
      for {path, method} <- [
            {"/posts", "get"},
            {"/posts/{id}", "get"},
            {"/posts", "post"},
            {"/posts/{id}", "patch"},
            {"/posts/{id}", "delete"},
            {"/posts/{id}/publish", "post"},
            {"/posts/{id}/comments", "get"}
          ] do
        assert %{"in" => "query", "schema" => %{"type" => "string"}} =
                 parameter(spec, path, method, "include"),
               "#{method} #{path} has no include parameter"
      end

      assert parameter(spec, "/posts/{id}", "delete", "include")["description"] =~
               "`author`, `comments`, `comments.author`"
    end

    test "is absent from value routes and resources without includes", %{spec: spec} do
      refute parameter(spec, "/posts/word_count", "get", "include")
      refute parameter(spec, "/posts/stats", "post", "include")
      refute parameter(spec, "/posts/ping", "post", "include")
      refute parameter(spec, "/notes/{id}", "get", "include")
      refute parameter(spec, "/notes", "get", "include")
      # The subtree under `comments.author` is empty.
      refute parameter(spec, "/comments/{id}/author", "get", "include")
    end
  end

  describe "get" do
    test "takes the primary key as path parameter and returns the record", %{spec: spec} do
      op = operation(spec, "/posts/{id}", "get")

      assert [
               %{"name" => "id", "in" => "path", "required" => true, "schema" => schema},
               %{"name" => "include", "in" => "query"}
             ] = op["parameters"]

      assert schema == %{"type" => "string", "format" => "uuid"}

      assert response_schema(spec, "/posts/{id}", "get", "200") == %{
               "$ref" => "#/components/schemas/Post"
             }

      assert op["responses"]["404"] == error_ref("NotFound")
      refute Map.has_key?(op, "requestBody")
    end
  end

  describe "index" do
    test "has filter, sort, page and include query parameters", %{spec: spec} do
      assert %{
               "in" => "query",
               "style" => "deepObject",
               "explode" => true,
               "schema" => filter,
               "description" => filter_desc
             } =
               parameter(spec, "/posts", "get", "filter")

      assert filter == %{"$ref" => "#/components/schemas/PostFilter"}
      assert filter_desc =~ "`filter[or][0][title]=A&filter[or][1][title]=B`"
      assert filter_desc =~ "`filter[not][title]=A`"

      assert %{"schema" => %{"type" => "string"}, "description" => sort_desc} =
               parameter(spec, "/posts", "get", "sort")

      assert sort_desc =~ "`created_at`"
      refute sort_desc =~ "inserted_at"

      assert %{"style" => "deepObject", "schema" => %{"properties" => page}} =
               parameter(spec, "/posts", "get", "page")

      assert Map.keys(page) |> Enum.sort() == ~w(after before count limit offset)
      assert page["limit"]["type"] == "integer"
      assert page["count"]["type"] == "boolean"

      assert %{"schema" => %{"type" => "string"}, "description" => include_desc} =
               parameter(spec, "/posts", "get", "include")

      assert include_desc =~ "`author`, `comments`, `comments.author`"

      assert response_schema(spec, "/posts", "get", "200") ==
               %{"$ref" => "#/components/schemas/PostList"}
    end

    test "page keys follow the action's pagination", %{spec: spec} do
      keyset = parameter(spec, "/posts/keyset", "get", "page")["schema"]["properties"]
      assert Map.keys(keyset) |> Enum.sort() == ~w(after before count limit)

      offset = parameter(spec, "/posts/offset", "get", "page")["schema"]["properties"]
      assert Map.keys(offset) |> Enum.sort() == ~w(count limit offset)
    end

    test "paginate? false has no page parameter and answers a data-only list", %{spec: spec} do
      assert parameter_names(spec, "/notes/paged", "get") == ~w(filter sort)

      assert response_schema(spec, "/notes/paged", "get", "200") ==
               %{"$ref" => "#/components/schemas/NoteUnpaginatedList"}

      assert response_schema(spec, "/notes", "get", "200") ==
               %{"$ref" => "#/components/schemas/NoteList"}
    end

    test "enable_filter? and enable_sort? false drop the parameters", %{spec: spec} do
      assert parameter_names(spec, "/notes/unfiltered", "get") == ~w(page)
    end

    test "the filter schema types each operator by its right-hand side", %{spec: spec} do
      filter = schema_of(spec, "PostFilter")

      assert %{"anyOf" => [%{"type" => "string"}, %{"properties" => ops}]} =
               filter["properties"]["title"]

      assert ops["eq"] == %{"type" => "string"}
      assert ops["not_eq"] == %{"type" => "string"}
      assert ops["in"] == %{"type" => "array", "items" => %{"type" => "string"}}
      assert ops["is_nil"] == %{"type" => "boolean"}
      assert Map.has_key?(ops, "less_than")

      assert Map.has_key?(filter["properties"], "created_at")
      refute Map.has_key?(filter["properties"], "inserted_at")
      refute Map.has_key?(filter["properties"], "internal_notes")

      assert %{"type" => "object"} = filter["properties"]["author"]
      assert %{"type" => "array", "description" => and_desc} = filter["properties"]["and"]
      assert and_desc =~ "`filter[or][0][title]=A&filter[or][1][title]=B`"
      assert %{"type" => "object"} = filter["properties"]["not"]
    end

    test "the filter schema lists every operator name the runtime accepts", %{spec: spec} do
      filter = schema_of(spec, "PostFilter")

      [_, %{"properties" => ops, "additionalProperties" => false}] =
        filter["properties"]["score"]["anyOf"]

      for {long, short} <- [
            {"greater_than", "gt"},
            {"greater_than_or_equal", "gte"},
            {"less_than", "lt"},
            {"less_than_or_equal", "lte"},
            {"eq", "equals"},
            {"not_eq", "not_equals"}
          ] do
        assert ops[long] == %{"type" => "integer"}, long
        assert ops[short] == %{"type" => "integer"}, short
      end

      refute Map.has_key?(ops, "like")
      refute Map.has_key?(ops, "contains")

      [_, %{"properties" => title_ops}] = filter["properties"]["title"]["anyOf"]
      assert title_ops["contains"] == %{"type" => "string"}
      assert title_ops["string_starts_with"] == %{"type" => "string"}
      assert title_ops["gt"] == %{"type" => "string"}
    end

    test "structured and record fields take the operators ash_rpc allows", %{spec: spec} do
      filter = schema_of(spec, "PostFilter")

      # An embedded resource compares as a record: `is_nil` only.
      [_, %{"properties" => settings}] = filter["properties"]["settings"]["anyOf"]
      assert Map.keys(settings) == ["is_nil"]

      # A union of a string and a map is structured: equality, no ordering.
      [_, %{"properties" => content}] = filter["properties"]["content"]["anyOf"]
      assert Map.has_key?(content, "eq")
      assert Map.has_key?(content, "in")
      assert Map.has_key?(content, "is_nil")
      refute Map.has_key?(content, "gt")
      refute Map.has_key?(content, "less_than")
    end

    test "filter schemas never reference themselves", %{spec: spec} do
      for name <- ~w(PostFilter AuthorFilter CommentFilter NoteFilter) do
        refute spec |> schema_of(name) |> Jason.encode!() |> String.contains?("#{name}\"}")
      end
    end

    test "secrets index documents 403", %{spec: spec} do
      assert operation(spec, "/secrets", "get")["responses"]["403"] == error_ref("Forbidden")
    end
  end

  describe "post and patch" do
    test "post has a request body from the action inputs and returns 201", %{spec: spec} do
      op = operation(spec, "/posts", "post")

      assert %{"required" => true, "content" => %{@json => %{"schema" => body}}} =
               op["requestBody"]

      assert body["required"] == ["title"]
      assert body["additionalProperties"] == false

      assert body["properties"]["title"] == %{
               "type" => "string",
               "description" => "The headline of the post."
             }

      assert body["properties"]["score"]["type"] == ["integer", "null"]
      assert body["properties"]["status"]["enum"] == ["draft", "published", nil]

      assert %{"anyOf" => [%{"$ref" => "#/components/schemas/PostSettings"}, _]} =
               body["properties"]["settings"]

      assert %{"anyOf" => [%{"oneOf" => [_, _]}, _]} = body["properties"]["content"]
      assert Map.has_key?(body["properties"], "published?")
      refute Map.has_key?(body["properties"], "created_at")
      refute Map.has_key?(body["properties"], "id")

      assert parameter_names(spec, "/posts", "post") == ~w(include)

      assert response_schema(spec, "/posts", "post", "201") == %{
               "$ref" => "#/components/schemas/Post"
             }

      assert op["responses"]["413"] == error_ref("PayloadTooLarge")
      assert op["responses"]["415"] == error_ref("UnsupportedMediaType")
    end

    test "patch requires nothing", %{spec: spec} do
      op = operation(spec, "/posts/{id}", "patch")

      assert %{"required" => false, "content" => %{@json => %{"schema" => body}}} =
               op["requestBody"]

      refute Map.has_key?(body, "required")
      assert Map.has_key?(body["properties"], "title")
      assert parameter_names(spec, "/posts/{id}", "patch") == ~w(id include)

      assert response_schema(spec, "/posts/{id}", "patch", "200") == %{
               "$ref" => "#/components/schemas/Post"
             }

      assert op["responses"]["404"] == error_ref("NotFound")
      assert op["responses"]["413"] == error_ref("PayloadTooLarge")
      assert op["responses"]["415"] == error_ref("UnsupportedMediaType")
    end

    test "delete returns the record and takes include", %{spec: spec} do
      assert response_schema(spec, "/posts/{id}", "delete", "200") ==
               %{"$ref" => "#/components/schemas/Post"}

      assert parameter_names(spec, "/posts/{id}", "delete") == ~w(id include)
      refute Map.has_key?(operation(spec, "/posts/{id}", "delete")["responses"], "415")
    end
  end

  describe "related" do
    test "to-many returns the destination list and scopes include to the subtree", %{spec: spec} do
      assert response_schema(spec, "/posts/{id}/comments", "get", "200") ==
               %{"$ref" => "#/components/schemas/BlogCommentList"}

      assert parameter(spec, "/posts/{id}/comments", "get", "filter")["schema"] ==
               %{"$ref" => "#/components/schemas/BlogCommentFilter"}

      assert parameter(spec, "/posts/{id}/comments", "get", "include")["description"] =~
               "`author`"

      assert [%{"name" => "id", "in" => "path"}] =
               Enum.filter(
                 operation(spec, "/posts/{id}/comments", "get")["parameters"],
                 &(&1["in"] == "path")
               )

      assert response_schema(spec, "/authors/{id}/posts", "get", "200") ==
               %{"$ref" => "#/components/schemas/PostList"}
    end

    test "page follows the relationship's read action, keyset included", %{spec: spec} do
      page = parameter(spec, "/posts/{id}/comments", "get", "page")["schema"]["properties"]
      assert Map.keys(page) |> Enum.sort() == ~w(after before count limit offset)

      page = parameter(spec, "/authors/{id}/posts", "get", "page")["schema"]["properties"]
      assert Map.keys(page) |> Enum.sort() == ~w(after before count limit offset)
    end

    test "enable_filter? and enable_sort? false drop the parameters", %{spec: spec} do
      assert parameter_names(spec, "/authors/{id}/posts_unfiltered", "get") == ~w(id page)
    end

    test "to-one takes no list parameters and returns a nullable record", %{spec: spec} do
      assert parameter_names(spec, "/comments/{id}/author", "get") == ~w(id)

      assert response_schema(spec, "/comments/{id}/author", "get", "200") ==
               %{"anyOf" => [%{"$ref" => "#/components/schemas/Author"}, %{"type" => "null"}]}
    end
  end

  describe "generic routes" do
    test "a GET route takes its query_params as query parameters and returns the raw value", %{
      spec: spec
    } do
      op = operation(spec, "/posts/word_count", "get")

      assert [
               %{
                 "name" => "text",
                 "in" => "query",
                 "required" => true,
                 "schema" => %{"type" => "string"}
               }
             ] = op["parameters"]

      refute Map.has_key?(op, "requestBody")
      assert response_schema(spec, "/posts/word_count", "get", "200") == %{"type" => "integer"}
    end

    test "a read route takes list parameters and its query_params", %{spec: spec} do
      assert parameter_names(spec, "/notes/search", "get") == ~w(filter sort q)

      assert %{"required" => true, "schema" => %{"type" => "string"}} =
               parameter(spec, "/notes/search", "get", "q")

      # The `search` action has no pagination: no `page`, data-only list.
      assert response_schema(spec, "/notes/search", "get", "200") ==
               %{"$ref" => "#/components/schemas/NoteUnpaginatedList"}

      assert parameter_names(spec, "/notes/search_index", "get") == ~w(filter sort q)
      assert parameter(spec, "/notes/search_index", "get", "q")["required"] == true
    end

    test "a get? read route returns the record", %{spec: spec} do
      assert response_schema(spec, "/notes/by_title/{title}", "get", "200") ==
               %{"$ref" => "#/components/schemas/Note"}
    end

    test "wrap_in_result? wraps the return value", %{spec: spec} do
      assert %{"required" => ["result"], "properties" => %{"result" => result}} =
               response_schema(spec, "/posts/stats", "post", "200")

      assert result == %{
               "type" => "object",
               "properties" => %{"total" => %{"type" => "integer"}},
               "required" => ["total"]
             }
    end

    test "an action without a return value answers with success", %{spec: spec} do
      assert %{"properties" => %{"success" => %{"const" => true}}, "required" => ["success"]} =
               response_schema(spec, "/posts/ping", "post", "200")
    end

    test "an update action route returns the record with its metadata", %{spec: spec} do
      op = operation(spec, "/posts/{id}/publish", "post")
      assert parameter_names(spec, "/posts/{id}/publish", "post") == ~w(id include)
      refute Map.has_key?(op, "requestBody")
      assert op["responses"]["415"] == error_ref("UnsupportedMediaType")

      assert %{
               "allOf" => [
                 %{"$ref" => "#/components/schemas/Post"},
                 %{"properties" => %{"meta" => meta}}
               ]
             } =
               response_schema(spec, "/posts/{id}/publish", "post", "200")

      assert meta["properties"]["published_by"] == %{"type" => ["string", "null"]}
    end
  end

  describe "resource schemas" do
    test "Post has a type const, default fields, includes and renamed fields", %{spec: spec} do
      post = schema_of(spec, "Post")
      props = post["properties"]

      assert props["type"]["const"] == "post"
      assert props["id"] == %{"type" => "string", "format" => "uuid"}
      assert props["created_at"]["format"] == "date-time"
      assert props["status"]["enum"] == ["draft", "published", nil]
      assert props["score"]["type"] == ["integer", "null"]
      assert props["comment_count"] == %{"type" => "integer"}
      assert props["title_length"]["type"] == ["integer", "null"]

      assert %{"anyOf" => [%{"$ref" => "#/components/schemas/PostSettings"}, %{"type" => "null"}]} =
               props["settings"]

      assert %{"anyOf" => [%{"oneOf" => [note, link]}, %{"type" => "null"}]} = props["content"]
      assert note["properties"] == %{"note" => %{"type" => "string"}}
      assert link["properties"]["link"]["required"] == ["url"]

      assert %{"anyOf" => [%{"$ref" => "#/components/schemas/Author"}, %{"type" => "null"}]} =
               props["author"]

      assert %{"type" => "array", "items" => %{"$ref" => "#/components/schemas/BlogComment"}} =
               props["comments"]

      refute Map.has_key?(props, "inserted_at")
      refute Map.has_key?(props, "internal_notes")
    end

    test "only type, id and non-nullable attributes are required", %{spec: spec} do
      # `comment_count` is a non-nullable aggregate: absent after an atomic
      # destroy, so it cannot be required.
      assert Enum.sort(schema_of(spec, "Post")["required"]) == ~w(created_at id title type)
      assert Enum.sort(schema_of(spec, "Note")["required"]) == ~w(id title type)
      assert Enum.sort(schema_of(spec, "BlogComment")["required"]) == ~w(body id type)
    end

    test "embedded resources are plain objects without a type", %{spec: spec} do
      settings = schema_of(spec, "PostSettings")
      assert settings["properties"]["featured"]["type"] == ["boolean", "null"]
      assert settings["properties"]["color"]["type"] == ["string", "null"]
      refute Map.has_key?(settings["properties"], "type")

      assert Map.keys(schema_of(spec, "Profile")["properties"]) |> Enum.sort() == ~w(bio website)
    end

    test "list wrappers carry the page keys", %{spec: spec} do
      list = schema_of(spec, "PostList")
      assert list["required"] == ["data"]

      assert list["properties"]["data"] == %{
               "type" => "array",
               "items" => %{"$ref" => "#/components/schemas/Post"}
             }

      assert Map.keys(list["properties"]) |> Enum.sort() ==
               ~w(count data has_more limit meta next_cursor offset prev_cursor)
    end

    test "unpaginated list wrappers carry data and meta only", %{spec: spec} do
      list = schema_of(spec, "NoteUnpaginatedList")
      assert list["required"] == ["data"]
      assert list["additionalProperties"] == false
      assert Map.keys(list["properties"]) |> Enum.sort() == ~w(data meta)

      assert list["properties"]["data"] == %{
               "type" => "array",
               "items" => %{"$ref" => "#/components/schemas/Note"}
             }

      # Only resources with an unpaginated route get one.
      refute schema_of(spec, "PostUnpaginatedList")
    end

    test "never uses nullable", %{spec: spec} do
      refute spec |> Jason.encode!() |> String.contains?("\"nullable\"")
    end
  end

  describe "sample payloads" do
    test "a record with an included relationship matches the resource schema", %{spec: spec} do
      post =
        Map.put(post_record(), "author", %{
          "id" => @uuid,
          "type" => "author",
          "name" => "Ada",
          "email" => nil,
          "profile" => nil
        })

      ref = %{"$ref" => "#/components/schemas/Post"}

      assert valid?(spec, ref, post)
      assert valid?(spec, ref, Map.drop(post_record(), ["body", "settings", "author_id"]))
      refute valid?(spec, ref, Map.put(post, "type", "comment"))
      refute valid?(spec, ref, Map.delete(post, "title"))
      refute valid?(spec, ref, Map.delete(post, "id"))

      refute valid?(
               spec,
               ref,
               Map.put(post, "content", %{"note" => "x", "link" => %{"url" => "y"}})
             )

      refute valid?(spec, ref, Map.put(post, "created_at", "yesterday"))
      refute valid?(spec, ref, Map.put(post, "author", %{"id" => @uuid, "name" => "Ada"}))
    end

    test "a deleted record without its aggregates and calculations matches", %{spec: spec} do
      ref = response_schema(spec, "/posts/{id}", "delete", "200")

      assert valid?(spec, ref, Map.drop(post_record(), ["comment_count", "title_length"]))
      refute valid?(spec, ref, Map.put(post_record(), "comment_count", "many"))
    end

    test "offset, keyset and plain pages match the list schema", %{spec: spec} do
      ref = %{"$ref" => "#/components/schemas/PostList"}

      assert valid?(spec, ref, %{
               "data" => [post_record()],
               "has_more" => true,
               "count" => 42,
               "limit" => 2,
               "offset" => 0
             })

      assert valid?(spec, ref, %{
               "data" => [post_record()],
               "has_more" => false,
               "count" => nil,
               "next_cursor" => "g3QAAA",
               "prev_cursor" => nil
             })

      assert valid?(spec, ref, %{"data" => []})
      refute valid?(spec, ref, %{"data" => [%{"id" => @uuid}]})
      refute valid?(spec, ref, [post_record()])
    end

    test "unpaginated lists carry no page keys", %{spec: spec} do
      ref = response_schema(spec, "/notes/paged", "get", "200")

      assert valid?(spec, ref, %{"data" => [note_record()]})
      assert valid?(spec, ref, %{"data" => [], "meta" => %{"returned" => 0}})
      refute valid?(spec, ref, %{"data" => [note_record()], "has_more" => false})
      refute valid?(spec, ref, %{"data" => [note_record()], "limit" => 2, "offset" => 0})
      refute valid?(spec, ref, %{"data" => [Map.delete(note_record(), "title")]})
    end

    test "filters match the filter schema", %{spec: spec} do
      ref = %{"$ref" => "#/components/schemas/PostFilter"}

      assert valid?(spec, ref, %{"title" => "A"})
      assert valid?(spec, ref, %{"title" => %{"contains" => "A", "not_eq" => "B"}})
      assert valid?(spec, ref, %{"score" => %{"gte" => 3, "lt" => 10}})
      assert valid?(spec, ref, %{"status" => %{"in" => ["draft", "published"]}})
      assert valid?(spec, ref, %{"created_at" => %{"gt" => "2026-01-01T00:00:00Z"}})
      assert valid?(spec, ref, %{"settings" => %{"is_nil" => true}})
      assert valid?(spec, ref, %{"author" => %{"name" => "Ada"}})

      assert valid?(spec, ref, %{
               "or" => [%{"title" => "A"}, %{"score" => %{"gte" => 5}}],
               "not" => %{"status" => "draft"}
             })

      refute valid?(spec, ref, %{"title" => %{"like" => "A"}})
      refute valid?(spec, ref, %{"score" => %{"gt" => "abc"}})
      refute valid?(spec, ref, %{"comment_count" => %{"contains" => "x"}})
      refute valid?(spec, ref, %{"title" => %{"in" => "A"}})
    end

    test "errors match the Error schema", %{spec: spec} do
      ref = %{"$ref" => "#/components/schemas/Error"}

      assert valid?(spec, ref, %{
               "error" => %{
                 "status" => 400,
                 "code" => "required",
                 "message" => "title is required",
                 "details" => [
                   %{"field" => "title", "code" => "required", "message" => "is required"}
                 ]
               }
             })

      assert valid?(spec, ref, %{
               "error" => %{
                 "status" => 400,
                 "code" => "invalid",
                 "message" => "two errors",
                 "details" => [
                   %{"field" => nil, "code" => "invalid", "message" => "one"},
                   %{"code" => "invalid", "message" => "two"}
                 ]
               }
             })

      assert valid?(spec, ref, %{
               "error" => %{"status" => 404, "code" => "not_found", "message" => "nope"}
             })

      refute valid?(spec, ref, %{"error" => %{"status" => 400, "message" => "no code"}})

      refute valid?(spec, ref, %{
               "error" => %{
                 "status" => 400,
                 "code" => "x",
                 "message" => "y",
                 "details" => [%{"field" => "a"}]
               }
             })
    end

    test "generic route results match their response schemas", %{spec: spec} do
      assert valid?(spec, response_schema(spec, "/posts/stats", "post", "200"), %{
               "result" => %{"total" => 42}
             })

      refute valid?(spec, response_schema(spec, "/posts/stats", "post", "200"), %{"total" => 42})

      assert valid?(spec, response_schema(spec, "/posts/ping", "post", "200"), %{
               "success" => true
             })

      assert valid?(spec, response_schema(spec, "/posts/word_count", "get", "200"), 3)

      published =
        Map.merge(post_record(), %{
          "status" => "published",
          "published?" => true,
          "meta" => %{"published_by" => "ash_rest"}
        })

      assert valid?(spec, response_schema(spec, "/posts/{id}/publish", "post", "200"), published)
    end
  end

  describe "serving through the router" do
    test "GET /openapi.json" do
      conn = Plug.Test.conn(:get, "/openapi.json") |> Router.call([])

      assert conn.status == 200
      assert get_resp_header(conn, "content-type") |> hd() =~ "application/json"

      assert %{"openapi" => "3.1.0", "info" => %{"title" => "AshRest test API"}} =
               Jason.decode!(conn.resp_body)
    end

    test "GET /docs serves Redoc" do
      conn = Plug.Test.conn(:get, "/docs") |> Router.call([])

      assert conn.status == 200
      assert get_resp_header(conn, "content-type") |> hd() =~ "text/html"
      assert conn.resp_body =~ "redoc"
      assert conn.resp_body =~ "/openapi.json"
    end
  end

  describe "Oaskit.Test.valid_response/3" do
    defp sent(path, operation_id, status, body) do
      Plug.Test.conn(:get, path)
      |> put_private(:oaskit, %{operation_id: operation_id})
      |> put_resp_content_type(@json)
      |> send_resp(status, Jason.encode!(body))
    end

    test "validates a response against the operation named in conn.private" do
      conn = sent("/posts/#{@uuid}", "post.get", 200, post_record())

      assert %{"type" => "post", "title" => "Hello"} =
               Oaskit.Test.valid_response(Router.OpenApi, conn, 200)
    end

    test "rejects a response that drifts from the document" do
      conn = sent("/posts/#{@uuid}", "post.get", 200, Map.delete(post_record(), "type"))

      assert_raise RuntimeError, ~r/invalid response returned by operation "post.get"/, fn ->
        Oaskit.Test.valid_response(Router.OpenApi, conn, 200)
      end
    end

    test "validates error envelopes, 413 and 415 included" do
      error = %{"error" => %{"status" => 404, "code" => "not_found", "message" => "No post"}}
      conn = sent("/posts/#{@uuid}", "post.get", 404, error)
      assert Oaskit.Test.valid_response(Router.OpenApi, conn, 404) == error

      too_large = %{
        "error" => %{"status" => 413, "code" => "request_too_large", "message" => "big"}
      }

      conn = sent("/posts", "post.post", 413, too_large)
      assert Oaskit.Test.valid_response(Router.OpenApi, conn, 413) == too_large

      not_json = %{
        "error" => %{"status" => 415, "code" => "unsupported_media_type", "message" => "x"}
      }

      conn = sent("/posts/ping", "post.ping", 415, not_json)
      assert Oaskit.Test.valid_response(Router.OpenApi, conn, 415) == not_json

      assert_raise RuntimeError, ~r/could not find response definition/, fn ->
        Oaskit.Test.valid_response(
          Router.OpenApi,
          sent("/posts/#{@uuid}", "post.get", 413, too_large),
          413
        )
      end
    end
  end
end
