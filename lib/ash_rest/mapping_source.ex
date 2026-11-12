# SPDX-FileCopyrightText: 2026 ash_rest contributors
#
# SPDX-License-Identifier: MIT

defmodule AshRest.MappingSource do
  @moduledoc false
  # Tells ash_rpc which resources are exposed, how fields are named on the
  # wire, and how each AshRest route becomes an `%AshRpc.Entrypoint{}`.
  # Called only while the manifest is decorated (see `AshRest.Manifest`).

  @behaviour AshRpc.MappingSource

  alias AshRest.Resource.Info

  @impl true
  def output_formatter, do: :snake_case

  @impl true
  def exposed_resource?(resource) do
    Info.rest_extension?(resource) or Ash.Resource.Info.embedded?(resource)
  rescue
    _ -> false
  end

  @impl true
  def field_names(resource) do
    if Info.rest_extension?(resource), do: Info.field_names(resource), else: %{}
  end

  @impl true
  def argument_names(resource, action) do
    if Info.rest_extension?(resource), do: Info.argument_names(resource, action), else: %{}
  end

  @impl true
  def type_field_names(_type), do: nil

  @impl true
  def entrypoint(%Ash.Info.Manifest.Entrypoint{
        resource: resource,
        action: action,
        config: %{ash_rest: %{route: route, domain: domain}}
      }) do
    base = %AshRpc.Entrypoint{
      name: route.name,
      domain: domain,
      resource: resource,
      action: action.name,
      # The REST layer computes `fields` itself and validates `include`
      # against the resource's `includes` tree, so no load restrictions here:
      # ash_rpc allow-lists would also block default calculations.
      load_restrictions: :none,
      exposed_metadata_fields: Enum.map(action.metadata || [], & &1.name)
    }

    case route.type do
      :get ->
        %{base | get_by: [Info.primary_key(resource)], not_found_error?: true}

      # Served through the parent's get; the flags gate the relationship
      # envelope's filter/sort (see AshRpc.FieldProcessing.FieldSelector).
      :related ->
        %{
          base
          | get_by: [Info.primary_key(resource)],
            not_found_error?: true,
            enable_filter?: route.enable_filter?,
            enable_sort?: route.enable_sort?
        }

      :index ->
        %{base | enable_filter?: route.enable_filter?, enable_sort?: route.enable_sort?}

      type when type in [:patch, :delete] ->
        %{base | identities: [:_primary_key], read_action: route.read_action}

      :route ->
        identity_entrypoint(base, route, action)

      _ ->
        base
    end
  end

  def entrypoint(_), do: nil

  # A generic `route` whose path has an `:id` segment and targets an
  # update/destroy action addresses one record by primary key.
  defp identity_entrypoint(base, route, action) do
    if action.type in [:update, :destroy] and ":id" in String.split(route.route, "/") do
      %{base | identities: [:_primary_key], read_action: route.read_action}
    else
      %{base | identities: []}
    end
  end
end
