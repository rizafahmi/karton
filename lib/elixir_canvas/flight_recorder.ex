defmodule ElixirCanvas.FlightRecorder do
  @moduledoc """
  Captures raw runtime logs and structured crash artifacts for local debugging.

  In development (and when explicitly enabled), `FlightRecorder`:

  1. Attaches a rotating OTP `:logger_std_h` file handler at `tmp/logs/dev.log`
     with timestamps, process metadata, and crash reasons.
  2. Attaches a `:telemetry` handler for Phoenix Router, LiveView, and
     LiveComponent exceptions plus forwarded browser errors
     (`[:elixir_canvas, :client, :error]`).
  3. Writes atomic, self-contained crash reproduction bundles to
     `tmp/crashes/crash-<timestamp>-<id>.json` (including git SHA, event name,
     sanitized parameters, stacktrace, and the in-memory version-1 canvas graph)
     and appends an index line to `tmp/logs/crashes.jsonl`.
  """

  require Logger

  alias ElixirCanvas.Document
  alias Hakushi.Graph

  @telemetry_handler_id :elixir_canvas_flight_recorder
  @file_logger_id :elixir_canvas_file_log
  @default_max_crashes 50
  @max_string_bytes 4_096

  @git_sha (case System.cmd("git", ["rev-parse", "--short=12", "HEAD"], stderr_to_stdout: true) do
              {sha, 0} -> String.trim(sha)
              _ -> "unknown"
            end)

  @telemetry_events [
    [:phoenix, :live_view, :mount, :exception],
    [:phoenix, :live_view, :handle_params, :exception],
    [:phoenix, :live_view, :handle_event, :exception],
    [:phoenix, :live_component, :handle_event, :exception],
    [:phoenix, :router_dispatch, :exception],
    [:elixir_canvas, :client, :error]
  ]

  @doc """
  Returns build and runtime metadata for traceability across logs and crash bundles.
  """
  def runtime_info do
    %{
      "app" => "elixir_canvas",
      "version" => to_string(Application.spec(:elixir_canvas, :vsn) || "0.1.0"),
      "git_sha" => @git_sha,
      "elixir_version" => System.version(),
      "otp_release" => to_string(:erlang.system_info(:otp_release))
    }
  end

  @doc """
  Returns the configured flight recorder options merged with defaults.
  """
  def config(overrides \\ []) do
    env_config = Application.get_env(:elixir_canvas, :flight_recorder, [])

    %{
      enabled: false,
      crashes_dir: Path.expand("tmp/crashes"),
      logs_dir: Path.expand("tmp/logs"),
      log_file: Path.expand("tmp/logs/dev.log"),
      max_crashes: @default_max_crashes,
      log_client_errors: true
    }
    |> Map.merge(Map.new(env_config))
    |> Map.merge(Map.new(overrides))
  end

  @doc """
  Sets up the telemetry crash recorder and optional rotating file logger.
  """
  def setup(overrides \\ []) do
    cfg = config(overrides)
    attach_telemetry(overrides)

    if cfg.enabled and is_binary(cfg.log_file) do
      attach_file_logger(cfg.log_file)
    else
      :ok
    end
  end

  @doc """
  Attaches the `:telemetry` crash handler idempotently.
  """
  def attach_telemetry(overrides \\ [], handler_id \\ @telemetry_handler_id) do
    :telemetry.detach(handler_id)

    :telemetry.attach_many(
      handler_id,
      @telemetry_events,
      &__MODULE__.handle_telemetry_event/4,
      Map.new(overrides)
    )
  end

  @doc """
  Detaches the `:telemetry` crash handler.
  """
  def detach_telemetry(handler_id \\ @telemetry_handler_id) do
    :telemetry.detach(handler_id)
  end

  @doc """
  Attaches a rotating OTP `:logger_std_h` file handler at `log_file`.
  """
  def attach_file_logger(log_file, handler_id \\ @file_logger_id)
      when is_binary(log_file) and is_atom(handler_id) do
    with :ok <- ensure_safe_directory(Path.dirname(log_file)),
         :ok <- ensure_not_symlink(log_file) do
      _ = :logger.remove_handler(handler_id)

      handler_config = %{
        level: :info,
        config: %{
          file: String.to_charlist(log_file),
          max_no_bytes: 5_242_880,
          max_no_files: 3
        },
        formatter:
          Logger.Formatter.new(
            format: "$date $time [$level] $metadata$message\n",
            metadata: [:request_id, :pid, :mfa, :file, :line]
          )
      }

      case :logger.add_handler(handler_id, :logger_std_h, handler_config) do
        :ok ->
          info = runtime_info()

          Logger.info(
            "ElixirCanvas file logger started git_sha=#{info["git_sha"]} version=#{info["version"]} otp=#{info["otp_release"]}"
          )

          :ok

        {:error, reason} ->
          {:error, reason}
      end
    end
  end

  @doc """
  Removes the rotating OTP file logger handler.
  """
  def detach_file_logger(handler_id \\ @file_logger_id) do
    :logger.remove_handler(handler_id)
  end

  @doc false
  def handle_telemetry_event(event_name, measurements, metadata, handler_overrides) do
    cfg = config(handler_overrides)

    if cfg.enabled do
      report = build_report(event_name, measurements, metadata)

      if event_name == [:elixir_canvas, :client, :error] and cfg.log_client_errors do
        Logger.error(
          "Client error [#{report["event"]}]: #{get_in(report, ["exception", "message"])} (id=#{report["id"]})"
        )
      end

      _ = persist_report(report, cfg)
    end

    :ok
  rescue
    _ -> :ok
  end

  @doc """
  Builds a structured, JSON-serializable crash report from a telemetry event.
  """
  def build_report(event_name, _measurements, metadata) do
    now = DateTime.utc_now()
    compact_ts = Calendar.strftime(now, "%Y%m%dT%H%M%SZ")
    unique = System.unique_integer([:positive, :monotonic])
    id = "crash-#{compact_ts}-#{unique}"
    socket = metadata[:socket]

    case event_name do
      [:elixir_canvas, :client, :error] ->
        params = sanitize_value(metadata[:params] || %{})
        kind = truncate_string(to_string(params["kind"] || "error"))
        message = truncate_string(to_string(params["message"] || "Uncaught client error"))

        %{
          "id" => id,
          "timestamp" => DateTime.to_iso8601(now),
          "source" => "client",
          "telemetry_event" => Enum.join(event_name, "."),
          "environment" => runtime_info(),
          "component" => inspect_module(metadata[:view] || socket_view(socket)),
          "event" => kind,
          "params" => params,
          "exception" => %{
            "kind" => kind,
            "module" => nil,
            "message" => message,
            "stacktrace" => split_stack_lines(params["stack"]),
            "source_url" => params["source"],
            "line" => if(is_integer(params["line"]), do: params["line"], else: nil),
            "column" => if(is_integer(params["column"]), do: params["column"], else: nil),
            "client_context" => %{
              "tool" => params["tool"],
              "selected_nodes" => List.wrap(params["selected_nodes"]),
              "selected_edges" => List.wrap(params["selected_edges"])
            }
          },
          "workspace" => extract_workspace(socket)
        }

      _ ->
        kind = metadata[:kind] || :error
        reason = metadata[:reason]
        stacktrace = metadata[:stacktrace] || []

        %{
          "id" => id,
          "timestamp" => DateTime.to_iso8601(now),
          "source" => "server",
          "telemetry_event" => Enum.join(event_name, "."),
          "environment" => runtime_info(),
          "component" =>
            inspect_module(
              metadata[:component] || metadata[:view] || socket_view(socket) || metadata[:plug]
            ),
          "event" => extract_event_name(metadata),
          "params" => sanitize_value(extract_params(metadata)),
          "exception" => %{
            "kind" => to_string(kind),
            "module" =>
              if(is_exception(reason), do: inspect_module(reason.__struct__), else: nil),
            "message" =>
              truncate_string(String.trim(Exception.format_banner(kind, reason, stacktrace))),
            "formatted" =>
              truncate_string(Exception.format(kind, reason, stacktrace), @max_string_bytes * 4),
            "stacktrace" => format_stacktrace(stacktrace)
          },
          "workspace" => extract_workspace(socket)
        }
    end
  end

  @doc """
  Persists a crash report atomically to `crashes_dir` and appends a summary line
  to `logs_dir/crashes.jsonl`.
  """
  def persist_report(%{"id" => id} = report, cfg \\ config()) do
    crashes_dir = Map.fetch!(cfg, :crashes_dir)
    logs_dir = Map.fetch!(cfg, :logs_dir)
    max_crashes = Map.get(cfg, :max_crashes, @default_max_crashes)

    with :ok <- ensure_safe_directory(crashes_dir),
         :ok <- ensure_safe_directory(logs_dir) do
      crash_path = Path.join(crashes_dir, "#{id}.json")
      tmp_path = Path.join(crashes_dir, ".#{id}.tmp")

      with :ok <- ensure_not_symlink(crash_path),
           :ok <- ensure_not_symlink(tmp_path),
           encoded <- Jason.encode_to_iodata!(report, pretty: true),
           :ok <- File.write(tmp_path, [encoded, "\n"]),
           :ok <- File.rename(tmp_path, crash_path) do
        append_crash_index(logs_dir, report, crash_path)
        prune_crashes(crashes_dir, max_crashes)
        {:ok, crash_path}
      else
        error ->
          _ = File.rm(tmp_path)
          error
      end
    end
  end

  @doc """
  Lists recorded crash reports from `crashes_dir`, newest first.
  """
  def list_crashes(opts \\ []) do
    crashes_dir = Keyword.get_lazy(opts, :crashes_dir, fn -> config().crashes_dir end)

    case File.ls(crashes_dir) do
      {:ok, entries} ->
        entries
        |> Enum.filter(&(String.starts_with?(&1, "crash-") and String.ends_with?(&1, ".json")))
        |> Enum.sort(:desc)
        |> Enum.flat_map(fn filename ->
          path = Path.join(crashes_dir, filename)

          with {:ok, bytes} <- File.read(path),
               {:ok, decoded} <- Jason.decode(bytes) do
            [Map.put(decoded, "crash_file", path)]
          else
            _ -> []
          end
        end)

      {:error, _} ->
        []
    end
  end

  defp append_crash_index(logs_dir, report, crash_path) do
    index_path = Path.join(logs_dir, "crashes.jsonl")

    if ensure_not_symlink(index_path) == :ok do
      summary = %{
        "id" => report["id"],
        "timestamp" => report["timestamp"],
        "source" => report["source"],
        "telemetry_event" => report["telemetry_event"],
        "component" => report["component"],
        "event" => report["event"],
        "message" => get_in(report, ["exception", "message"]),
        "git_sha" => get_in(report, ["environment", "git_sha"]),
        "crash_file" => crash_path
      }

      _ = File.write(index_path, [Jason.encode_to_iodata!(summary), "\n"], [:append])
    end
  end

  defp prune_crashes(crashes_dir, max_crashes)
       when is_integer(max_crashes) and max_crashes > 0 do
    case File.ls(crashes_dir) do
      {:ok, entries} ->
        entries
        |> Enum.filter(&(String.starts_with?(&1, "crash-") and String.ends_with?(&1, ".json")))
        |> Enum.sort(:desc)
        |> Enum.drop(max_crashes)
        |> Enum.each(fn stale ->
          _ = File.rm(Path.join(crashes_dir, stale))
        end)

      _ ->
        :ok
    end
  end

  defp prune_crashes(_crashes_dir, _max_crashes), do: :ok

  defp extract_event_name(metadata) do
    cond do
      is_binary(metadata[:event]) -> metadata[:event]
      match?(%Plug.Conn{}, metadata[:conn]) -> metadata.conn.request_path
      is_binary(metadata[:route]) -> metadata[:route]
      true -> "unknown"
    end
  end

  defp extract_params(metadata) do
    cond do
      is_map(metadata[:params]) -> metadata[:params]
      is_map(metadata[:unsigned_params]) -> metadata[:unsigned_params]
      match?(%Plug.Conn{}, metadata[:conn]) -> metadata.conn.params
      true -> %{}
    end
  end

  defp socket_view(%{view: view}), do: view
  defp socket_view(_), do: nil

  defp inspect_module(nil), do: nil

  defp inspect_module(module) when is_atom(module) do
    inspect(module)
  end

  defp inspect_module(other), do: to_string(other)

  defp format_stacktrace(stacktrace) when is_list(stacktrace) do
    stacktrace
    |> Enum.take(25)
    |> Enum.map(fn
      {mod, fun, arity_or_args, location} ->
        arity = if is_list(arity_or_args), do: length(arity_or_args), else: arity_or_args
        file = Keyword.get(location, :file)
        line = Keyword.get(location, :line)

        %{
          "module" => inspect(mod),
          "function" => to_string(fun),
          "arity" => arity,
          "file" => if(file, do: to_string(file), else: nil),
          "line" => line,
          "formatted" => Exception.format_stacktrace_entry({mod, fun, arity_or_args, location})
        }

      other ->
        %{"formatted" => inspect(other)}
    end)
  end

  defp format_stacktrace(_), do: []

  defp split_stack_lines(stack) when is_binary(stack) do
    stack
    |> truncate_string(@max_string_bytes * 2)
    |> String.split("\n", trim: true)
    |> Enum.take(25)
  end

  defp split_stack_lines(_), do: []

  defp extract_workspace(%{assigns: assigns}) when is_map(assigns) do
    document = Map.get(assigns, :document)
    graph = Map.get(assigns, :graph) || (document && document.graph)

    %{
      "persistence" =>
        if(document && document.persistence, do: to_string(document.persistence), else: nil),
      "filename" => if(document, do: document.filename, else: nil),
      "path" => if(document, do: document.path, else: nil),
      "dirty" => Map.get(assigns, :dirty),
      "drawing_font" =>
        Map.get(assigns, :drawing_font) || (document && Document.drawing_font(document)),
      "disk_status" =>
        if(Map.get(assigns, :disk_status), do: to_string(assigns.disk_status), else: nil),
      "generation" => Map.get(assigns, :generation),
      "edit_version" => Map.get(assigns, :edit_version),
      "graph" => serialize_graph(document, graph)
    }
  end

  defp extract_workspace(_), do: nil

  defp serialize_graph(document, %Graph{} = graph) do
    with %Document{} <- document,
         {:ok, bytes, _prepared} <- Document.prepare_save(document, graph),
         {:ok, decoded} <- Jason.decode(bytes) do
      decoded
    else
      _ ->
        %{
          "version" => 1,
          "node_order" => graph.node_order,
          "nodes" =>
            Enum.map(Graph.nodes(graph), fn node ->
              %{
                "id" => node.id,
                "type" => node.type,
                "x" => node.x,
                "y" => node.y,
                "width" => node.width,
                "height" => node.height,
                "locked" => node.locked,
                "data" => sanitize_value(node.data)
              }
            end),
          "edges" =>
            Enum.map(Graph.edges(graph), fn edge ->
              %{
                "id" => edge.id,
                "source" => edge.source,
                "source_handle" => edge.source_handle,
                "target" => edge.target,
                "target_handle" => edge.target_handle,
                "path" => to_string(edge.path),
                "marker" => to_string(edge.marker),
                "label" => edge.label,
                "animated" => edge.animated,
                "data" => sanitize_value(edge.data)
              }
            end)
        }
    end
  end

  defp serialize_graph(_document, _graph), do: nil

  defp sanitize_value(value) when is_binary(value), do: truncate_string(value)

  defp sanitize_value(value) when is_boolean(value) or is_number(value) or is_nil(value),
    do: value

  defp sanitize_value(value) when is_atom(value), do: to_string(value)

  defp sanitize_value(%_{} = struct) do
    struct
    |> Map.from_struct()
    |> Map.put("__struct__", inspect(struct.__struct__))
    |> sanitize_value()
  end

  defp sanitize_value(value) when is_map(value) do
    value
    |> Enum.take(100)
    |> Map.new(fn {k, v} -> {to_string(k), sanitize_value(v)} end)
  end

  defp sanitize_value(value) when is_list(value) do
    value
    |> Enum.take(100)
    |> Enum.map(&sanitize_value/1)
  end

  defp sanitize_value(value) when is_tuple(value) do
    value
    |> Tuple.to_list()
    |> sanitize_value()
  end

  defp sanitize_value(other), do: inspect(other)

  defp truncate_string(value, max_bytes \\ @max_string_bytes)

  defp truncate_string(value, max_bytes) when is_binary(value) do
    if not String.valid?(value) do
      "<<binary:#{byte_size(value)} bytes>>"
    else
      if byte_size(value) <= max_bytes do
        value
      else
        binary_part(value, 0, max_bytes) <> "...[truncated]"
      end
    end
  end

  defp ensure_safe_directory(dir) do
    case File.lstat(dir) do
      {:ok, %{type: :symlink}} ->
        {:error, :symlink}

      {:ok, %{type: :directory}} ->
        :ok

      {:ok, _} ->
        {:error, :not_a_directory}

      {:error, :enoent} ->
        case File.mkdir_p(dir) do
          :ok -> ensure_not_symlink(dir)
          error -> error
        end

      error ->
        error
    end
  end

  defp ensure_not_symlink(path) do
    case File.lstat(path) do
      {:ok, %{type: :symlink}} -> {:error, :symlink}
      {:ok, _} -> :ok
      {:error, :enoent} -> :ok
      error -> error
    end
  end
end
