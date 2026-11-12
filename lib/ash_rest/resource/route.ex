# SPDX-FileCopyrightText: 2026 ash_rest contributors
#
# SPDX-License-Identifier: MIT

# Adapted from ash_json_api (MIT), https://github.com/ash-project/ash_json_api
defmodule AshRest.Resource.Route do
  @moduledoc """
  A route declared in a resource's `rest.routes` section.

  Built by the DSL entities in `AshRest` and completed by
  `AshRest.Resource.Transformers.SetRouteDefaults`, so after compilation:

    * `route` is the full path including `base`, e.g. `"/posts/:id"`
    * `action_type` is the type of the resource action
    * `name` is the entrypoint name (defaults to `"<type>.<route kind>"`)
    * `resource` is the resource module
  """

  @type method :: :get | :post | :patch | :put | :delete
  @type route_type :: :get | :index | :post | :patch | :delete | :related | :route

  @type t :: %__MODULE__{
          route: String.t(),
          action: atom(),
          action_type: :read | :create | :update | :destroy | :action | nil,
          method: method(),
          type: route_type(),
          relationship: atom() | nil,
          read_action: atom() | nil,
          name: String.t() | nil,
          description: String.t() | nil,
          summary: String.t() | nil,
          request_body_description: String.t() | nil,
          response_description: String.t() | nil,
          parameter_descriptions: [{atom(), String.t()}],
          tags: [String.t()] | nil,
          deprecated?: boolean(),
          resource: module() | nil,
          primary?: boolean(),
          paginate?: boolean(),
          query_params: [atom()],
          metadata: (term(), term(), term() -> map()) | nil,
          modify_conn: (term(), term(), term(), term() -> term()) | nil,
          wrap_in_result?: boolean(),
          enable_filter?: boolean(),
          enable_sort?: boolean(),
          __spark_metadata__: term()
        }

  defstruct [
    :route,
    :action,
    :action_type,
    :method,
    :type,
    :relationship,
    :read_action,
    :name,
    :description,
    :summary,
    :request_body_description,
    :response_description,
    :tags,
    :resource,
    parameter_descriptions: [],
    deprecated?: false,
    primary?: false,
    paginate?: true,
    query_params: [],
    metadata: nil,
    modify_conn: nil,
    wrap_in_result?: false,
    enable_filter?: true,
    enable_sort?: true,
    __spark_metadata__: nil
  ]
end
