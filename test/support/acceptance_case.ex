# SPDX-FileCopyrightText: 2026 ash_rest contributors
#
# SPDX-License-Identifier: MIT

defmodule AshRest.AcceptanceCase do
  @moduledoc false
  # Shared setup of the acceptance suite. Requests go through `AshRest.Test`,
  # which validates every routed response against the router's OpenAPI document
  # (`AshRest.Test.validate_openapi(true)` in test_helper.exs).
  #
  # Tags excluded by default (see test_helper.exs):
  #   * `:spec_mismatch` - the response does not match the generated OpenAPI document
  #   * `:runtime_bug` - the runtime does not behave as documented
  use ExUnit.CaseTemplate

  using do
    quote do
      import AshRest.Test
      import AshRest.AcceptanceCase

      alias AshRest.TestApp.{Author, Comment, Note, Post, Router, Secret}
    end
  end

  alias AshRest.TestApp.{Author, Comment, Note, Post}

  def create_author(attrs \\ %{}) do
    Ash.create!(Author, Map.merge(%{name: "Ada", profile: %{bio: "hi"}}, attrs))
  end

  def create_post(author, attrs \\ %{}) do
    Ash.create!(Post, Map.merge(%{title: "Hello world", author_id: author.id}, attrs))
  end

  def create_comment(post, attrs \\ %{}) do
    Ash.create!(Comment, Map.merge(%{body: "nice", post_id: post.id}, attrs))
  end

  def create_note(attrs \\ %{}), do: Ash.create!(Note, Map.merge(%{title: "Note"}, attrs))

  @doc "The titles of the records of a list response, in order."
  def titles(conn),
    do: conn |> AshRest.Test.json() |> Map.fetch!("data") |> Enum.map(& &1["title"])
end
