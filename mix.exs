# SPDX-FileCopyrightText: 2026 ash_rest contributors
#
# SPDX-License-Identifier: MIT

defmodule AshRest.MixProject do
  use Mix.Project

  @version "0.1.0"
  @description "A flat, Stripe-style REST API extension for the Ash Framework, built on ash_rpc."
  @source_url "https://github.com/xantrac/ash_rest"

  def project do
    [
      app: :ash_rest,
      version: @version,
      elixir: "~> 1.15",
      description: @description,
      elixirc_paths: elixirc_paths(Mix.env()),
      start_permanent: Mix.env() == :prod,
      consolidate_protocols: Mix.env() == :prod,
      deps: deps(),
      docs: &docs/0,
      aliases: aliases(),
      package: package(),
      source_url: @source_url,
      homepage_url: @source_url,
      dialyzer: [plt_add_apps: [:ex_unit, :mix]]
    ]
  end

  def application do
    [extra_applications: [:logger]]
  end

  defp elixirc_paths(:test), do: ["test/support/", "lib/"]
  defp elixirc_paths(_), do: ["lib/"]

  defp package do
    [
      name: :ash_rest,
      licenses: ["MIT"],
      files:
        ~w(lib .formatter.exs mix.exs README* LICENSE* CHANGELOG* documentation usage-rules.md),
      links: %{"GitHub" => @source_url}
    ]
  end

  defp docs do
    [
      main: "readme",
      source_ref: "v#{@version}",
      extras: [
        {"README.md", title: "Home"},
        "documentation/topics/getting-started.md",
        "documentation/topics/routes.md",
        "documentation/topics/filtering-sorting-pagination.md",
        "documentation/topics/errors.md",
        {"documentation/dsls/DSL-AshRest.md", search_data: Spark.Docs.search_data_for(AshRest)},
        {"documentation/dsls/DSL-AshRest.Domain.md",
         search_data: Spark.Docs.search_data_for(AshRest.Domain)},
        "CHANGELOG.md"
      ],
      groups_for_extras: [
        Topics: ~r'documentation/topics',
        DSLs: ~r'documentation/dsls'
      ],
      groups_for_modules: [
        AshRest: [AshRest, AshRest.Router, AshRest.Domain, AshRest.Test],
        Introspection: [AshRest.Resource.Info, AshRest.Domain.Info, AshRest.Resource.Route],
        Internals: ~r/.*/
      ]
    ]
  end

  defp deps do
    [
      {:ash, "~> 3.37"},
      {:ash_rpc,
       git: "https://github.com/ash-project/ash_rpc.git",
       ref: "741a85569e2af5ab8025d8bb2b1cb8f6a25ab6f4"},
      {:spark, "~> 2.2"},
      {:plug, "~> 1.14"},
      {:jason, "~> 1.4"},
      {:phoenix, "~> 1.7", optional: true},
      {:oaskit, "~> 0.18", optional: true},
      {:igniter, "~> 0.6", optional: true},
      {:ex_doc, "~> 0.37", only: [:dev, :test], runtime: false},
      {:ex_check, "~> 0.16", only: [:dev, :test]},
      {:credo, ">= 0.0.0", only: [:dev, :test], runtime: false},
      {:dialyxir, ">= 0.0.0", only: [:dev, :test], runtime: false},
      {:sobelow, ">= 0.0.0", only: [:dev, :test], runtime: false},
      {:mix_audit, ">= 0.0.0", only: [:dev, :test], runtime: false},
      {:bandit, "~> 1.0", only: [:dev, :test]},
      {:simple_sat, ">= 0.0.0", only: [:dev, :test]}
    ]
  end

  defp aliases do
    [
      sobelow: "sobelow --skip",
      credo: "credo --strict",
      docs: [
        "spark.cheat_sheets",
        "docs",
        "spark.replace_doc_links"
      ],
      "spark.formatter": "spark.formatter --extensions AshRest,AshRest.Domain",
      "spark.cheat_sheets": "spark.cheat_sheets --extensions AshRest,AshRest.Domain"
    ]
  end
end
