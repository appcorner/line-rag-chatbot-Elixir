defmodule ChatService.MixProject do
  use Mix.Project

  def project do
    [
      app: :chat_service,
      version: "0.1.0",
      elixir: "~> 1.17",
      elixirc_paths: elixirc_paths(Mix.env()),
      start_permanent: Mix.env() == :prod,
      aliases: aliases(),
      deps: deps(),
      compilers: Mix.compilers()
    ]
  end

  def application do
    [
      mod: {ChatService.Application, []},
      extra_applications: [:logger, :runtime_tools, :crypto, :os_mon]
    ]
  end

  defp elixirc_paths(:test), do: ["lib", "test/support"]
  defp elixirc_paths(_), do: ["lib"]

  defp deps do
    [
      {:phoenix, "~> 1.7"},
      {:phoenix_html, "~> 4.1"},
      {:phoenix_html_helpers, "~> 1.0"},
      {:gettext, "~> 0.26"},
      {:phoenix_live_view, "~> 1.0"},
      {:phoenix_live_dashboard, "~> 0.8"},
      {:phoenix_pubsub, "~> 2.1"},
      {:plug_cowboy, "~> 2.7"},
      {:jason, "~> 1.4"},
      {:finch, "~> 0.18"},
      {:req, "~> 0.5"},
      {:redix, "~> 1.3"},
      {:hammer, "~> 6.2"},
      {:telemetry, "~> 1.2"},
      {:telemetry_metrics, "~> 1.0"},
      {:telemetry_poller, "~> 1.0"},
      {:ecto, "~> 3.11"},
      {:ecto_sql, "~> 3.11"},
      {:postgrex, "~> 0.18"},
      # Ecto Stats for LiveDashboard
      {:ecto_psql_extras, "~> 0.8"},
      {:html_entities, "~> 0.5"},
      {:dns_cluster, "~> 0.1.3"},
      {:bandit, "~> 1.5"},
      {:credo, "~> 1.7", only: [:dev, :test], runtime: false},
      {:dialyxir, "~> 1.4", only: [:dev, :test], runtime: false},
      {:esbuild, "~> 0.8", runtime: Mix.env() == :dev},
      {:tailwind, "~> 0.2", runtime: Mix.env() == :dev},
      {:phoenix_live_reload, "~> 1.5", only: :dev},
      {:cors_plug, "~> 3.0"},
      {:oban, "~> 2.18"},
      {:broadway, "~> 1.1"},
      {:broadway_rabbitmq, "~> 0.8"},
      {:amqp, "~> 3.3"}
    ]
  end

  defp aliases do
    [
      setup: ["deps.get", "ecto.setup", "assets.setup", "assets.build"],
      "ecto.setup": ["ecto.create", "ecto.migrate"],
      "ecto.reset": ["ecto.drop", "ecto.setup"],
      "assets.setup": ["tailwind.install --if-missing", "esbuild.install --if-missing"],
      "assets.build": ["tailwind chat_service", "esbuild chat_service"],
      "assets.deploy": [
        "tailwind chat_service --minify",
        "esbuild chat_service --minify",
        "phx.digest"
      ]
    ]
  end
end
