# SPDX-FileCopyrightText: 2026 ash_rest contributors
#
# SPDX-License-Identifier: MIT

defmodule AshRest.Manifest do
  @moduledoc """
  Builds and caches the ash_rpc-decorated `Ash.Info.Manifest` for a router.

  Every route of every `AshRest` resource in the router's domains becomes one
  manifest entrypoint, named after the route (`"post.get"`, `"post.index"`, …).
  The manifest is built on first use and cached in `:persistent_term`; call
  `clear/1` after hot code reloading in development.
  """

  @doc "The decorated manifest for `router`, built once and cached."
  @spec get(module()) :: Ash.Info.Manifest.t()
  def get(router) do
    key = {__MODULE__, router}

    case :persistent_term.get(key, nil) do
      nil ->
        manifest = build(router)
        :persistent_term.put(key, manifest)
        manifest

      manifest ->
        manifest
    end
  end

  @doc "Forgets the cached manifest for `router`."
  @spec clear(module()) :: :ok
  def clear(router) do
    :persistent_term.erase({__MODULE__, router})
    :ok
  end

  @doc "Builds the decorated manifest for `router` without caching it."
  @spec build(module()) :: Ash.Info.Manifest.t()
  def build(router) do
    entrypoints =
      for {domain, resource, route} <- routes(router) do
        %{
          resource: resource,
          action: route.action,
          config: %{ash_rest: %{name: route.name, route: route, domain: domain}}
        }
      end

    {:ok, manifest} =
      Ash.Info.Manifest.Generator.generate(
        otp_app: router.__ash_rest__(:otp_app),
        action_entrypoints: entrypoints
      )

    AshRpc.Manifest.Decorator.decorate(manifest, AshRest.MappingSource)
  end

  @doc "Every `{domain, resource, route}` the router serves."
  @spec routes(module()) :: [{module(), module(), AshRest.Resource.Route.t()}]
  def routes(router) do
    for domain <- router.__ash_rest__(:domains),
        resource <- Ash.Domain.Info.resources(domain),
        AshRest.Resource.Info.rest_extension?(resource),
        route <- AshRest.Resource.Info.routes(resource) do
      {domain, resource, route}
    end
  end

  @doc "The decorated manifest resource for `module`, or nil."
  @spec resource(Ash.Info.Manifest.t(), module()) :: Ash.Info.Manifest.Resource.t() | nil
  def resource(manifest, module),
    do: manifest |> AshRpc.Manifest.resource_lookup() |> Map.get(module)

  @doc "The manifest action backing the entrypoint named `name`."
  @spec action(Ash.Info.Manifest.t(), module(), atom()) :: Ash.Info.Manifest.Action.t() | nil
  def action(manifest, resource, action_name) do
    manifest
    |> AshRpc.Manifest.action_lookup()
    |> Ash.Info.Manifest.get_action(resource, action_name)
  end

  @doc "The client (wire) name of `field` on `resource`."
  @spec client_name(Ash.Info.Manifest.t(), module(), atom()) :: String.t()
  def client_name(manifest, resource, field) do
    manifest
    |> resource(resource)
    |> AshRpc.Manifest.Custom.field_names()
    |> Map.get(field, to_string(field))
  end
end
