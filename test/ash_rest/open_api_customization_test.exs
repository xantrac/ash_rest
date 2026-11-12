# SPDX-FileCopyrightText: 2026 ash_rest contributors
#
# SPDX-License-Identifier: MIT

defmodule AshRest.OpenApiCustomizationTest do
  use ExUnit.Case, async: true

  alias AshRest.TestApp.Router

  defmodule CustomRouter do
    @moduledoc false
    use AshRest.Router,
      domains: [AshRest.TestApp.Domain],
      open_api_info: [
        title: "Custom API",
        version: "2.0.0",
        description: "Everything about the blog.",
        terms_of_service: "https://example.com/terms",
        contact: [name: "API team", email: "api@example.com"],
        license: [name: "MIT", url: "https://opensource.org/licenses/MIT"]
      ]

    @impl AshRest.Router
    def modify_open_api(spec) do
      spec
      |> Map.put("servers", [%{"url" => "https://api.example.com"}])
      |> put_in(["components", "securitySchemes"], %{
        "bearer" => %{"type" => "http", "scheme" => "bearer"}
      })
    end
  end

  defmodule ClashA do
    @moduledoc false
    use Ash.Resource,
      domain: AshRest.OpenApiCustomizationTest.ClashDomain,
      data_layer: Ash.DataLayer.Ets,
      extensions: [AshRest]

    rest do
      base "/a"

      routes do
        index :read
      end

      open_api do
        schema_name "Thing"
      end
    end

    attributes do
      uuid_primary_key :id
    end

    actions do
      defaults [:read]
    end
  end

  defmodule ClashB do
    @moduledoc false
    use Ash.Resource,
      domain: AshRest.OpenApiCustomizationTest.ClashDomain,
      data_layer: Ash.DataLayer.Ets,
      extensions: [AshRest]

    rest do
      base "/b"

      routes do
        index :read
      end

      open_api do
        schema_name "Thing"
      end
    end

    attributes do
      uuid_primary_key :id
    end

    actions do
      defaults [:read]
    end
  end

  defmodule ClashDomain do
    @moduledoc false
    use Ash.Domain, validate_config_inclusion?: false

    resources do
      resource AshRest.OpenApiCustomizationTest.ClashA
      resource AshRest.OpenApiCustomizationTest.ClashB
    end
  end

  defmodule ClashRouter do
    @moduledoc false
    use AshRest.Router, domains: [AshRest.OpenApiCustomizationTest.ClashDomain], open_api: false
  end

  setup_all do
    %{spec: AshRest.OpenApi.spec(Router)}
  end

  defp operation(spec, path, method), do: spec["paths"][path][method]

  defp parameter(op, name), do: Enum.find(op["parameters"], &(&1["name"] == name))

  describe "per-endpoint documentation" do
    test "a route's summary, description, response and parameter descriptions", %{spec: spec} do
      op = operation(spec, "/posts/{id}/publish", "post")

      assert op["summary"] == "Publish a post"

      assert op["description"] ==
               "Marks the post as published and stamps `published_by`.\n" <>
                 "Publishing an already published post is a no-op.\n"

      assert op["responses"]["200"]["description"] ==
               "The published post, with `meta.published_by`."

      assert parameter(op, "id")["description"] == "The post's UUID"
    end

    test "a request body description", %{spec: spec} do
      assert operation(spec, "/posts", "post")["requestBody"]["description"] ==
               "The post to create."
    end

    test "without overrides, descriptions come from the Ash action and its arguments",
         %{spec: spec} do
      op = operation(spec, "/posts/word_count", "get")

      assert op["description"] == "Counts the words in a text."
      assert parameter(op, "text")["description"] == "The text to count words in."
    end

    test "summaries and success descriptions keep their defaults", %{spec: spec} do
      op = operation(spec, "/posts/{id}", "get")

      assert op["summary"] == "Fetch a post"
      assert op["responses"]["200"]["description"] == "The record."
      refute Map.has_key?(op, "deprecated")
    end

    test "tags and deprecation", %{spec: spec} do
      index = operation(spec, "/comments", "get")

      assert index["summary"] == "List comments"
      assert index["tags"] == ["Comments", "Moderation"]
      assert index["deprecated"] == true

      assert operation(spec, "/comments/{id}", "get")["tags"] == ["Comments"]
      assert operation(spec, "/posts/{id}", "get")["tags"] == ["post"]
    end
  end

  describe "resource-level open_api section" do
    test "top-level tags list every tag in use, with descriptions", %{spec: spec} do
      tags = Map.new(spec["tags"], &{&1["name"], &1})

      assert tags["Comments"] == %{
               "name" => "Comments",
               "description" => "Reader comments on posts."
             }

      assert tags["Moderation"] == %{"name" => "Moderation"}
      assert tags["post"] == %{"name" => "post"}
      assert Enum.map(spec["tags"], & &1["name"]) == Enum.sort(Map.keys(tags))
    end

    test "schema_name renames the resource's component schemas", %{spec: spec} do
      schemas = spec["components"]["schemas"]

      assert schemas["BlogComment"]["description"] == "A reader's comment on a post."
      assert Map.has_key?(schemas, "BlogCommentList")
      assert Map.has_key?(schemas, "BlogCommentFilter")
      refute Map.has_key?(schemas, "Comment")

      assert %{"items" => %{"$ref" => "#/components/schemas/BlogComment"}} =
               schemas["Post"]["properties"]["comments"]
    end

    test "resource and field descriptions come from Ash", %{spec: spec} do
      post = spec["components"]["schemas"]["Post"]

      assert post["description"] == "A blog post."
      assert post["properties"]["title"]["description"] == "The headline of the post."
    end

    test "two resources with the same schema name raise" do
      assert_raise ArgumentError, ~r/both use the OpenAPI schema name "Thing"/, fn ->
        AshRest.OpenApi.spec(ClashRouter)
      end
    end
  end

  describe "router-level customization" do
    setup do
      %{custom: AshRest.OpenApi.spec(CustomRouter)}
    end

    test "open_api_info supports camelized and nested keys", %{custom: custom} do
      assert custom["info"] == %{
               "title" => "Custom API",
               "version" => "2.0.0",
               "description" => "Everything about the blog.",
               "termsOfService" => "https://example.com/terms",
               "contact" => %{"name" => "API team", "email" => "api@example.com"},
               "license" => %{"name" => "MIT", "url" => "https://opensource.org/licenses/MIT"}
             }
    end

    test "modify_open_api/1 runs last", %{custom: custom} do
      assert custom["servers"] == [%{"url" => "https://api.example.com"}]

      assert custom["components"]["securitySchemes"] == %{
               "bearer" => %{"type" => "http", "scheme" => "bearer"}
             }

      assert Map.has_key?(custom["components"]["schemas"], "Post")
    end

    test "the customized documents are valid OpenAPI 3.1", %{spec: spec, custom: custom} do
      for document <- [spec, custom] do
        assert %Oaskit.Spec.OpenAPI{} =
                 document |> Oaskit.normalize_spec!() |> Oaskit.SpecValidator.validate!()
      end

      assert {_built, _root} =
               Oaskit.build_spec!(CustomRouter.OpenApi, responses: true, cache: false)
    end

    test "the default modify_open_api/1 returns the document unchanged" do
      assert Router.modify_open_api(%{"x" => 1}) == %{"x" => 1}
    end
  end
end
