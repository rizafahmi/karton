defmodule ElixirCanvas.MixProject do
  use Mix.Project

  @source_url "https://github.com/rizafahmi/elixir_canvas"
  @version "0.1.0"

  def project do
    [
      app: :elixir_canvas,
      version: @version,
      name: "Elixir Canvas",
      description:
        "A local-file-first spatial thinking canvas built with Elixir, Phoenix LiveView, and Hakushi. The JSON file is the document.",
      source_url: @source_url,
      homepage_url: @source_url,
      elixir: "~> 1.18",
      elixirc_paths: elixirc_paths(Mix.env()),
      start_permanent: Mix.env() == :prod,
      aliases: aliases(),
      deps: deps(),
      package: package(),
      compilers: [:phoenix_live_view] ++ Mix.compilers(),
      listeners: [Phoenix.CodeReloader]
    ]
  end

  # Configuration for the OTP application.
  #
  # Type `mix help compile.app` for more information.
  def application do
    [
      mod: {ElixirCanvas.Application, []},
      extra_applications: [:logger, :runtime_tools]
    ]
  end

  def cli do
    [
      preferred_envs: [check: :test, precommit: :test]
    ]
  end

  # Specifies which paths to compile per environment.
  defp elixirc_paths(:test), do: ["lib", "test/support"]
  defp elixirc_paths(_), do: ["lib"]

  # Specifies your project dependencies.
  #
  # Type `mix help deps` for examples and options.
  defp deps do
    [
      {:phoenix, "~> 1.8.5"},
      {:phoenix_html, "~> 4.1"},
      {:phoenix_live_reload, "~> 1.2", only: :dev},
      {:phoenix_live_view, "~> 1.1.0"},
      {:hakushi, "~> 0.7.0"},
      {:lazy_html, ">= 0.1.0", only: :test},
      {:esbuild, "~> 0.10", runtime: Mix.env() == :dev},
      {:telemetry_metrics, "~> 1.0"},
      {:telemetry_poller, "~> 1.0"},
      {:jason, "~> 1.2"},
      {:bandit, "~> 1.5"}
    ]
  end

  # Aliases are shortcuts or tasks specific to the current project.
  # For example, to install project dependencies and perform other setup tasks, run:
  #
  #     $ mix setup
  #
  # See the documentation for `Mix` for more info on aliases.
  defp aliases do
    [
      setup: ["deps.get", "assets.deps", "assets.setup", "assets.build"],
      "assets.deps": ["cmd npm --prefix assets ci --ignore-scripts --no-audit --no-fund"],
      "assets.setup": ["esbuild.install --if-missing"],
      "assets.build": ["compile", "esbuild elixir_canvas"],
      "assets.deploy": [
        "esbuild elixir_canvas --minify",
        "phx.digest"
      ],
      check: [
        "format --check-formatted",
        "compile --warnings-as-errors",
        &check_js/1,
        "assets.build",
        "test"
      ],
      precommit: [
        "compile --warnings-as-errors",
        "deps.unlock --unused",
        "format",
        "test",
        &check_js/1,
        "assets.build"
      ]
    ]
  end

  defp check_js(_args) do
    js_files = Path.wildcard("assets/js/**/*.js") |> Enum.sort()

    if js_files == [] do
      Mix.raise("No JavaScript source files found under assets/js")
    end

    for file <- js_files do
      case System.cmd("sh", ["-c", ~s(node --input-type=module --check < "$1"), "--", file],
             into: IO.stream(:stdio, :line),
             stderr_to_stdout: true
           ) do
        {_, 0} -> :ok
        {_, status} -> Mix.raise("JavaScript syntax check failed for #{file} (exit #{status})")
      end
    end

    js_tests = Path.wildcard("test/**/*_test.mjs") |> Enum.sort()

    if js_tests == [] do
      Mix.raise("No JavaScript test files found under test/")
    end

    case System.cmd("node", ["--test" | js_tests],
           into: IO.stream(:stdio, :line),
           stderr_to_stdout: true
         ) do
      {_, 0} -> :ok
      {_, status} -> Mix.raise("JavaScript unit tests failed (exit #{status})")
    end
  end

  defp package do
    [
      licenses: ["MIT"],
      links: %{
        "GitHub" => @source_url,
        "Design System" => "#{@source_url}/blob/main/DESIGN.md"
      },
      keywords: [
        "elixir",
        "phoenix",
        "liveview",
        "hakushi",
        "canvas",
        "spatial-thinking",
        "whiteboard",
        "diagramming",
        "local-first",
        "json",
        "mindmap",
        "neo-acid"
      ]
    ]
  end
end
