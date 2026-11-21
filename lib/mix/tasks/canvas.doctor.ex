defmodule Mix.Tasks.Canvas.Doctor do
  @shortdoc "Inspects build traceability, example corpus integrity, raw logs, and crash bundles"

  @moduledoc """
  Runs a read-only diagnostic check of the repository and local runtime artifacts.

      mix canvas.doctor
      mix canvas.doctor --json
      mix canvas.doctor --strict
      mix canvas.doctor --clear-crashes

  ## Options

    * `--json` - prints the full diagnostic report as structured JSON for coding agents
    * `--strict` - exits with status 1 if any health check fails or crash bundles are present
    * `--clear-crashes` - removes recorded crash bundles (`tmp/crashes/crash-*.json` and
      `tmp/logs/crashes.jsonl`) after investigation
  """

  use Mix.Task

  alias ElixirCanvas.{Document, FlightRecorder}

  @impl Mix.Task
  def run(args) do
    {opts, _rest, _invalid} =
      OptionParser.parse(args,
        strict: [json: :boolean, strict: :boolean, clear_crashes: :boolean]
      )

    if opts[:clear_crashes] == true do
      cleared = clear_crashes()

      if opts[:json] != true do
        Mix.shell().info("Cleared #{cleared} crash bundle(s).")
      end
    end

    report = collect_report()

    if opts[:json] == true do
      Mix.shell().info(Jason.encode!(report, pretty: true))
    else
      print_human_report(report)
    end

    if opts[:strict] == true and report["status"] != "healthy" do
      Mix.raise("Canvas doctor reported status=#{report["status"]}")
    end

    report
  end

  @doc """
  Collects a structured health and diagnostic report. Accepts overrides for testing.
  """
  def collect_report(overrides \\ []) do
    cfg = FlightRecorder.config(overrides)
    runtime = FlightRecorder.runtime_info()
    head_sha = Keyword.get_lazy(overrides, :head_sha, &current_git_sha/0)
    modified_examples = Keyword.get_lazy(overrides, :modified_examples, &git_modified_examples/0)

    examples_glob =
      Keyword.get(overrides, :examples_glob, Path.expand("examples/*.{karton,json}"))

    assets_check =
      check_assets_freshness(
        Keyword.get(overrides, :source_assets_glob, Path.expand("assets/{js,css}/**/*.{js,css}")),
        Keyword.get(overrides, :built_js_path, Path.expand("priv/static/assets/js/app.js")),
        Keyword.get(overrides, :built_css_path, Path.expand("priv/static/assets/css/app.css"))
      )

    examples_report = check_examples(examples_glob, modified_examples)
    crashes = FlightRecorder.list_crashes(crashes_dir: cfg.crashes_dir)
    log_report = inspect_log_file(cfg.log_file)

    crashes_summary =
      Enum.map(crashes, fn crash ->
        crash_sha = get_in(crash, ["environment", "git_sha"])

        %{
          "id" => crash["id"],
          "timestamp" => crash["timestamp"],
          "source" => crash["source"],
          "event" => crash["event"],
          "component" => crash["component"],
          "message" => get_in(crash, ["exception", "message"]),
          "git_sha" => crash_sha,
          "matches_head" => crash_sha == head_sha,
          "has_graph_snapshot" => is_map(get_in(crash, ["workspace", "graph"])),
          "crash_file" => crash["crash_file"]
        }
      end)

    issues =
      []
      |> maybe_add_issue(
        runtime["git_sha"] != "unknown" and head_sha != "unknown" and
          runtime["git_sha"] != head_sha,
        "compiled_build_stale",
        "Compiled build SHA (#{runtime["git_sha"]}) differs from git HEAD (#{head_sha}). Run `mix compile`."
      )
      |> maybe_add_issue(
        not assets_check["fresh"],
        "assets_stale_or_missing",
        assets_check["detail"]
      )
      |> maybe_add_issue(
        examples_report["invalid"] != [],
        "invalid_examples",
        "#{length(examples_report["invalid"])} bundled example file(s) failed validation."
      )
      |> maybe_add_issue(
        examples_report["modified_in_git"] != [],
        "modified_examples",
        "Bundled example file(s) have uncommitted changes: #{Enum.join(examples_report["modified_in_git"], ", ")}"
      )
      |> maybe_add_issue(
        crashes_summary != [],
        "recorded_crashes",
        "#{length(crashes_summary)} crash bundle(s) present in #{cfg.crashes_dir}."
      )

    %{
      "status" => if(issues == [], do: "healthy", else: "attention_needed"),
      "timestamp" => DateTime.utc_now() |> DateTime.to_iso8601(),
      "traceability" => %{
        "head_git_sha" => head_sha,
        "compiled_git_sha" => runtime["git_sha"],
        "build_matches_head" =>
          runtime["git_sha"] == head_sha or runtime["git_sha"] == "unknown" or
            head_sha == "unknown",
        "version" => runtime["version"],
        "elixir_version" => runtime["elixir_version"],
        "otp_release" => runtime["otp_release"],
        "assets" => assets_check
      },
      "examples" => examples_report,
      "crashes" => %{
        "directory" => cfg.crashes_dir,
        "count" => length(crashes_summary),
        "recent" => Enum.take(crashes_summary, 10)
      },
      "logs" => log_report,
      "issues" => issues
    }
  end

  @doc """
  Removes recorded crash bundles (`crash-*.json`) and `crashes.jsonl`.
  """
  def clear_crashes(overrides \\ []) do
    cfg = FlightRecorder.config(overrides)

    removed_count =
      case File.ls(cfg.crashes_dir) do
        {:ok, entries} ->
          entries
          |> Enum.filter(&(String.starts_with?(&1, "crash-") and String.ends_with?(&1, ".json")))
          |> Enum.count(fn file ->
            path = Path.join(cfg.crashes_dir, file)

            case File.lstat(path) do
              {:ok, %{type: :regular}} -> File.rm(path) == :ok
              _ -> false
            end
          end)

        {:error, _} ->
          0
      end

    index_path = Path.join(cfg.logs_dir, "crashes.jsonl")

    case File.lstat(index_path) do
      {:ok, %{type: :regular}} -> _ = File.rm(index_path)
      _ -> :ok
    end

    removed_count
  end

  defp check_examples(examples_glob, modified_examples) do
    files = examples_glob |> Path.wildcard() |> Enum.sort()

    {valid, invalid} =
      Enum.reduce(files, {[], []}, fn path, {ok_acc, err_acc} ->
        rel = Path.relative_to_cwd(path)

        with {:ok, document} <- Document.open(path),
             {:ok, encoded, prepared} <- Document.prepare_save(document, document.graph),
             {:ok, roundtripped, _source} <- Document.decode(encoded),
             true <- roundtripped == prepared.graph do
          {[rel | ok_acc], err_acc}
        else
          {:error, reason} ->
            {ok_acc, [%{"file" => rel, "reason" => to_string(reason)} | err_acc]}

          false ->
            {ok_acc, [%{"file" => rel, "reason" => "Round-trip graph mismatch"} | err_acc]}
        end
      end)

    %{
      "total" => length(files),
      "valid_count" => length(valid),
      "invalid" => Enum.reverse(invalid),
      "modified_in_git" => modified_examples
    }
  end

  defp check_assets_freshness(source_glob, built_js_path, built_css_path) do
    sources = Path.wildcard(source_glob)

    with {:ok, js_stat} <- File.stat(built_js_path, time: :posix),
         {:ok, css_stat} <- File.stat(built_css_path, time: :posix) do
      built_mtime = min(js_stat.mtime, css_stat.mtime)

      newest_source_mtime =
        sources
        |> Enum.flat_map(fn path ->
          case File.stat(path, time: :posix) do
            {:ok, stat} -> [stat.mtime]
            _ -> []
          end
        end)
        |> Enum.max(fn -> 0 end)

      if built_mtime >= newest_source_mtime do
        %{
          "fresh" => true,
          "detail" => "Static assets in priv/static/assets are up to date."
        }
      else
        %{
          "fresh" => false,
          "detail" =>
            "Source files in assets/ are newer than priv/static/assets. Run `mix assets.build`."
        }
      end
    else
      _ ->
        %{
          "fresh" => false,
          "detail" =>
            "Built static assets are missing in priv/static/assets. Run `mix assets.build`."
        }
    end
  end

  defp inspect_log_file(log_file) when is_binary(log_file) do
    case File.stat(log_file) do
      {:ok, %{size: size}} ->
        lines =
          case File.read(log_file) do
            {:ok, contents} ->
              contents
              |> String.split("\n", trim: true)
              |> Enum.take(-200)

            _ ->
              []
          end

        recent_errors =
          lines
          |> Enum.filter(&(&1 =~ "[error]" or &1 =~ "[warning]"))
          |> Enum.take(-10)

        %{
          "path" => log_file,
          "exists" => true,
          "size_bytes" => size,
          "recent_warnings_and_errors" => recent_errors
        }

      {:error, _} ->
        %{
          "path" => log_file,
          "exists" => false,
          "size_bytes" => 0,
          "recent_warnings_and_errors" => []
        }
    end
  end

  defp inspect_log_file(_),
    do: %{"path" => nil, "exists" => false, "size_bytes" => 0, "recent_warnings_and_errors" => []}

  defp current_git_sha do
    case System.cmd("git", ["rev-parse", "--short=12", "HEAD"], stderr_to_stdout: true) do
      {sha, 0} -> String.trim(sha)
      _ -> "unknown"
    end
  end

  defp git_modified_examples do
    case System.cmd("git", ["status", "--porcelain", "--", "examples/"], stderr_to_stdout: true) do
      {output, 0} ->
        output
        |> String.split("\n", trim: true)
        |> Enum.map(fn line ->
          line |> String.slice(3..-1//1) |> String.trim()
        end)

      _ ->
        []
    end
  end

  defp maybe_add_issue(issues, false, _code, _message), do: issues

  defp maybe_add_issue(issues, true, code, message) do
    issues ++ [%{"code" => code, "message" => message}]
  end

  defp print_human_report(report) do
    trace = report["traceability"]
    examples = report["examples"]
    crashes = report["crashes"]
    logs = report["logs"]

    Mix.shell().info("=== Elixir Canvas Doctor (#{report["status"]}) ===")

    Mix.shell().info(
      "Build:     v#{trace["version"]} | HEAD=#{trace["head_git_sha"]} | compiled=#{trace["compiled_git_sha"]} | Elixir #{trace["elixir_version"]} / OTP #{trace["otp_release"]}"
    )

    Mix.shell().info("Assets:    #{trace["assets"]["detail"]}")

    Mix.shell().info(
      "Examples:  #{examples["valid_count"]}/#{examples["total"]} valid | modified in git: #{length(examples["modified_in_git"])}"
    )

    Mix.shell().info("Crashes:   #{crashes["count"]} bundle(s) in #{crashes["directory"]}")

    for crash <- crashes["recent"] do
      Mix.shell().info(
        "  - [#{crash["source"]}] #{crash["id"]} (#{crash["event"]}) sha=#{crash["git_sha"]}: #{crash["message"]}\n    file: #{crash["crash_file"]}"
      )
    end

    Mix.shell().info(
      "Dev log:   #{logs["path"]} (exists=#{logs["exists"]}, #{logs["size_bytes"]} bytes, #{length(logs["recent_warnings_and_errors"])} recent warning/error line(s))"
    )

    if report["issues"] != [] do
      Mix.shell().info("\nIssues requiring attention:")

      for issue <- report["issues"] do
        Mix.shell().info("  * [#{issue["code"]}] #{issue["message"]}")
      end
    end
  end
end
