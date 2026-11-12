# SPDX-FileCopyrightText: 2026 ash_rest contributors
#
# SPDX-License-Identifier: MIT

defmodule AshRest.Acceptance.ErrorsTest do
  @moduledoc false
  # Content negotiation, routing, policies, error handlers and
  # show_raised_errors?. Error envelopes are validated against the document.
  use AshRest.AcceptanceCase, async: true

  alias AshRest.TestApp.{HandledRouter, VerboseRouter}

  describe "content negotiation" do
    test "415 for a non-JSON body on write routes" do
      Router
      |> post("/posts", nil, raw_body: "title=x", content_type: "text/plain", status: 415)
      |> assert_error(415, "unsupported_media_type")

      note = create_note()

      Router
      |> patch("/notes/#{note.id}", nil,
        raw_body: "title=x",
        content_type: "application/x-www-form-urlencoded",
        status: 415
      )
      |> assert_error(415, "unsupported_media_type")

      Router
      |> put("/notes/#{note.id}", nil, raw_body: "<a/>", content_type: "text/xml", status: 415)
      |> assert_error(415, "unsupported_media_type")
    end

    test "400 for invalid JSON and for a body that is not an object" do
      Router
      |> post("/posts", nil, raw_body: "{not json", status: 400)
      |> assert_error(400, "invalid_body")

      Router
      |> post("/posts", [1, 2], status: 400)
      |> assert_error(400, "invalid_body")
    end

    # `post.ping` takes no input and has no requestBody, but 415 is declared.
    test "415 on a route without a request body" do
      Router
      |> post("/posts/ping", nil, raw_body: "x", content_type: "text/plain", status: 415)
      |> assert_error(415, "unsupported_media_type")
    end

    test "413 for a body over the parser limit" do
      body = Jason.encode!(%{title: String.duplicate("a", 8_100_000)})

      # Validation against the document is covered by the spec_mismatch test below.
      conn = post(Router, "/posts", nil, raw_body: body, status: 413, openapi: false)
      assert_error(conn, 413, "request_too_large")

      # The router sets the operation id before parsing the body, so this
      # response (and the invalid-JSON 400) can be validated against the operation.
      assert conn.private.oaskit.operation_id == "post.post"
    end

    test "400 for invalid JSON carries the operation id" do
      conn = post(Router, "/posts", nil, raw_body: "{not json", status: 400)
      assert conn.private.oaskit.operation_id == "post.post"
    end

    # Plug.Parsers' body limit (8 MB) produces 413 on every write route; the
    # router sets the operation id before parsing, so `post/4` validates it.
    test "413 is declared by write operations" do
      body = Jason.encode!(%{title: String.duplicate("a", 8_100_000)})

      conn = post(Router, "/posts", nil, raw_body: body, status: 413)
      assert %{oaskit: %{operation_id: "post.post"}} = conn.private
      assert_error(conn, 413, "request_too_large")
    end

    # Plug.Parsers skips a body without a content type; the controller reads it
    # itself and rejects it when it is not empty.
    test "415 for a body without a content type" do
      Router
      |> post("/posts", nil, raw_body: ~s({"title": "x"}), content_type: nil, status: 415)
      |> assert_error(415, "unsupported_media_type")

      # an empty body without a content type is "no input"
      Router
      |> post("/posts/ping", nil, content_type: nil, status: 200)
      |> then(&assert(json(&1) == %{"success" => true}))
    end

    test "JSON with a charset or a +json subtype is accepted" do
      Router
      |> post("/posts", %{title: "x"}, content_type: "application/json; charset=utf-8")
      |> assert_record(%{"title" => "x"})

      Router
      |> post("/posts", %{title: "y"}, content_type: "application/vnd.api+json")
      |> assert_record(%{"title" => "y"})
    end

    # Behind an upstream Plug.Parsers that accepts urlencoded bodies (the
    # default Phoenix endpoint), form bodies arrive already parsed: the content
    # type decides, not whether body_params was parsed.
    test "415 for a form body parsed upstream" do
      parsers =
        Plug.Parsers.init(parsers: [:urlencoded, :json], pass: ["*/*"], json_decoder: Jason)

      conn =
        Plug.Test.conn(:post, "/posts", "title=Form")
        |> Plug.Conn.put_req_header("content-type", "application/x-www-form-urlencoded")
        |> Plug.Parsers.call(parsers)
        |> Router.call([])

      assert_error(conn, 415, "unsupported_media_type")
    end
  end

  describe "routing" do
    test "404 no_route_found for unknown paths and methods" do
      Router
      |> get("/nothing/here", status: 404)
      |> assert_error(404, "no_route_found")
      |> then(&assert(&1["message"] == "No route found for GET /nothing/here"))

      Router
      |> put("/posts", %{}, status: 404)
      |> assert_error(404, "no_route_found")
    end

    test "literal segments win over path params" do
      create_post(create_author(), %{title: "Listed"})

      assert Router |> get("/posts/keyset") |> titles() == ["Listed"]
    end

    test "the OpenAPI document and the Redoc page are served" do
      conn = Plug.Test.conn(:get, "/openapi.json") |> Router.call([])
      assert conn.status == 200

      assert %{"openapi" => "3.1.0", "paths" => %{"/notes/{id}" => _}} =
               Jason.decode!(conn.resp_body)

      conn = Plug.Test.conn(:get, "/docs") |> Router.call([])
      assert conn.status == 200
      assert conn.resp_body =~ "/openapi.json"
    end
  end

  describe "policies" do
    test "403 without an actor, 200 with an admin actor" do
      Router
      |> get("/secrets", status: 403)
      |> assert_error(403, "forbidden")

      Router
      |> get("/secrets", actor: %{role: :user}, status: 403)
      |> assert_error(403, "forbidden")

      Router
      |> get("/secrets", actor: %{role: :admin})
      |> assert_list(0)

      Ash.create!(Secret, %{value: "s3cr3t"}, authorize?: false)

      Router
      |> get("/secrets?filter[value]=s3cr3t", actor: %{role: :admin})
      |> assert_list([%{"type" => "secret", "value" => "s3cr3t"}])
    end

    test "403 for a forbidden create" do
      Router
      |> post("/secrets", %{value: "x"}, actor: %{role: :admin}, status: 403)
      |> assert_error(403, "forbidden")
    end
  end

  describe "error_handler (router option)" do
    test "rewrites messages of action errors" do
      conn = post(HandledRouter, "/posts", %{}, status: 400)

      assert %{"message" => "please provide it"} = assert_error(conn, 400, "required")
      assert %{"message" => "please provide it"} = assert_error_detail(conn, "title", "required")
    end

    test "dropped errors leave the others; dropping every error is a 500" do
      conn = post(HandledRouter, "/posts", %{score: "abc"}, status: 400)
      assert_error_detail(conn, "title", "required")
      refute Enum.any?(json(conn)["error"]["details"], &(&1["code"] == "invalid_attribute"))

      HandledRouter
      |> post("/posts", %{title: "x", score: "abc"}, status: 500)
      |> assert_error(500, "internal_error")
      |> then(&assert(&1["message"] == "An error occurred"))
    end

    test "request errors found before the action runs are not handled" do
      HandledRouter
      |> post("/posts", %{title: "x", bogus: 1}, status: 400)
      |> assert_error_detail("bogus", "unknown_input")
      |> then(&assert(&1["message"] == "Unknown input bogus"))
    end
  end

  describe "show_raised_errors? (router option)" do
    @tag capture_log: true
    test "an exception's message is shown" do
      error =
        VerboseRouter
        |> post("/notes/explode", %{}, status: 500)
        |> assert_error(500, "unknown_error")

      assert error["message"] =~ "boom"
    end

    # With show_raised_errors? true, ash_rpc renders every Ash exception from
    # its module name (AshRpc.Errors.raised_error/1): a policy failure arrives
    # as "policy". AshRest.Errors maps the forbidden exceptions back to
    # "forbidden" / 403.
    test "a policy failure is still 403 forbidden" do
      VerboseRouter
      |> get("/secrets", status: 403)
      |> assert_error(403, "forbidden")

      VerboseRouter
      |> post("/posts", %{}, status: 400)
      |> assert_error(400, "required")
    end

    # RUNTIME BUG (ash_rpc): AshRpc.Errors.raised_error/1 builds the error from
    # the exception alone, with `fields: []`, so validation errors lose the
    # field they are about and `details` disappear. Needs an upstream change
    # (fall back to the AshRpc.Error protocol's `fields`/`path`); AshRest
    # cannot recover the field from the message.
    @tag :runtime_bug
    test "validation errors keep their details" do
      VerboseRouter
      |> post("/posts", %{}, status: 400)
      |> assert_error_detail("title", "required")
    end
  end
end
