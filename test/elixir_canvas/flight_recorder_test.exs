defmodule ElixirCanvas.FlightRecorderTest do
  use ElixirCanvasWeb.ConnCase, async: false

  import Phoenix.LiveViewTest

  alias ElixirCanvas.{Document, FlightRecorder}
  alias Hakushi.{Change, Graph}

  @moduletag :tmp_dir

  setup %{tmp_dir: tmp_dir} do
    crashes_dir = Path.join(tmp_dir, "crashes")
    logs_dir = Path.join(tmp_dir, "logs")
    canvas_path = Path.join(tmp_dir, "ideas.json")
    File.cp!(Path.expand("../../shared/fixtures/v1/document.json", __DIR__), canvas_path)

    handler_id = {:test_flight_recorder, System.unique_integer([:positive])}

    overrides = %{
      enabled: true,
      crashes_dir: crashes_dir,
      logs_dir: logs_dir,
      log_file: nil,
      max_crashes: 3,
      log_client_errors: false
    }

    :ok = FlightRecorder.attach_telemetry(overrides, handler_id)

    on_exit(fn ->
      FlightRecorder.detach_telemetry(handler_id)
    end)

    %{
      tmp_dir: tmp_dir,
      crashes_dir: crashes_dir,
      logs_dir: logs_dir,
      canvas_path: canvas_path,
      overrides: overrides
    }
  end

  test "records server LiveView exception with full in-memory graph and stacktrace for replay", %{
    crashes_dir: crashes_dir,
    logs_dir: logs_dir,
    canvas_path: canvas_path
  } do
    {:ok, document} = Document.open(canvas_path)

    {:ok, moved_graph, _, _} =
      Graph.apply(document.graph, Change.move([%{id: "idea", x: 312.5, y: -48.0}]))

    socket = %Phoenix.LiveView.Socket{
      view: ElixirCanvasWeb.CanvasLive,
      assigns: %{
        __changed__: %{},
        document: document,
        graph: moved_graph,
        dirty: true,
        drawing_font: "mono",
        disk_status: :unchanged,
        generation: 2,
        edit_version: 5
      }
    }

    stacktrace = [
      {ElixirCanvasWeb.DrawingCanvas, :handle_event, 3,
       [file: ~c"lib/elixir_canvas_web/drawing_canvas.ex", line: 80]}
    ]

    :telemetry.execute(
      [:phoenix, :live_view, :handle_event, :exception],
      %{duration: 1_200},
      %{
        socket: socket,
        view: ElixirCanvasWeb.CanvasLive,
        event: "drawing:edge-style",
        params: %{"edges" => ["idea-to-make"], "key" => "stroke", "value" => "red"},
        kind: :error,
        reason: %ArgumentError{message: "synthetic crash during edge style update"},
        stacktrace: stacktrace
      }
    )

    assert [crash] = FlightRecorder.list_crashes(crashes_dir: crashes_dir)
    assert crash["source"] == "server"
    assert crash["telemetry_event"] == "phoenix.live_view.handle_event.exception"
    assert crash["component"] == "ElixirCanvasWeb.CanvasLive"
    assert crash["event"] == "drawing:edge-style"
    assert crash["params"] == %{"edges" => ["idea-to-make"], "key" => "stroke", "value" => "red"}
    assert crash["environment"]["app"] == "elixir_canvas"
    assert is_binary(crash["environment"]["git_sha"])
    assert crash["exception"]["module"] == "ArgumentError"
    assert crash["exception"]["message"] =~ "synthetic crash during edge style update"

    assert [%{"module" => "ElixirCanvasWeb.DrawingCanvas", "line" => 80}] =
             crash["exception"]["stacktrace"]

    workspace = crash["workspace"]
    assert workspace["persistence"] == "server_file"
    assert workspace["filename"] == "ideas.json"
    assert workspace["dirty"] == true
    assert workspace["drawing_font"] == "mono"

    # The captured graph in the crash bundle can be decoded directly back into a valid Document graph
    repro_bytes = Jason.encode!(workspace["graph"])
    assert {:ok, repro_graph, _source} = Document.decode(repro_bytes)
    assert Graph.node(repro_graph, "idea").x == 312.5
    assert Graph.node(repro_graph, "idea").y == -48.0

    # Also writes a summary entry to logs/crashes.jsonl
    index_lines =
      Path.join(logs_dir, "crashes.jsonl")
      |> File.read!()
      |> String.split("\n", trim: true)
      |> Enum.map(&Jason.decode!/1)

    assert [%{"id" => id, "event" => "drawing:edge-style", "crash_file" => crash_file}] =
             index_lines

    assert id == crash["id"]
    assert File.regular?(crash_file)
  end

  test "CanvasLive forwards browser client-error hook events into crash bundles without losing canvas state",
       %{
         conn: conn,
         crashes_dir: crashes_dir,
         canvas_path: canvas_path,
         overrides: overrides
       } do
    previous_env = Application.get_env(:elixir_canvas, :flight_recorder)
    previous_file = System.get_env("CANVAS_FILE")
    Application.put_env(:elixir_canvas, :flight_recorder, Map.to_list(overrides))
    System.put_env("CANVAS_FILE", canvas_path)

    on_exit(fn ->
      if previous_env do
        Application.put_env(:elixir_canvas, :flight_recorder, previous_env)
      else
        Application.delete_env(:elixir_canvas, :flight_recorder)
      end

      if previous_file do
        System.put_env("CANVAS_FILE", previous_file)
      else
        System.delete_env("CANVAS_FILE")
      end
    end)

    {:ok, view, _html} = live(conn, ~p"/")

    render_hook(view, "client-error", %{
      "kind" => "error",
      "message" => "TypeError: Cannot read properties of null (reading 'x')",
      "stack" =>
        "TypeError: Cannot read properties of null\n    at apply (assets/js/app.js:120:15)",
      "source" => "http://localhost:4000/assets/js/app.js",
      "line" => 120,
      "column" => 15,
      "tool" => "drawing:rect",
      "selected_nodes" => ["idea"],
      "selected_edges" => []
    })

    assert [crash | _] = FlightRecorder.list_crashes(crashes_dir: crashes_dir)
    assert crash["source"] == "client"
    assert crash["event"] == "error"
    assert crash["exception"]["message"] =~ "Cannot read properties of null"
    assert crash["exception"]["line"] == 120
    assert crash["exception"]["client_context"]["tool"] == "drawing:rect"
    assert crash["exception"]["client_context"]["selected_nodes"] == ["idea"]
    assert crash["workspace"]["filename"] == "ideas.json"
    assert is_map(crash["workspace"]["graph"])

    # LiveView workspace remains responsive
    assert has_element?(view, "#workspace[data-file-name='ideas.json']")
  end

  test "prunes oldest crash bundles beyond max_crashes and refuses symlinked crash directories",
       %{
         tmp_dir: tmp_dir,
         crashes_dir: crashes_dir,
         overrides: overrides
       } do
    for idx <- 1..5 do
      report =
        FlightRecorder.build_report(
          [:phoenix, :live_view, :handle_event, :exception],
          %{},
          %{
            event: "event-#{idx}",
            kind: :error,
            reason: %RuntimeError{message: "boom #{idx}"},
            stacktrace: []
          }
        )

      assert {:ok, _path} = FlightRecorder.persist_report(report, overrides)
    end

    crashes = FlightRecorder.list_crashes(crashes_dir: crashes_dir)
    assert length(crashes) == 3
    assert Enum.map(crashes, & &1["event"]) == ["event-5", "event-4", "event-3"]

    symlink_dir = Path.join(tmp_dir, "symlink-crashes")
    File.ln_s!(crashes_dir, symlink_dir)

    report =
      FlightRecorder.build_report(
        [:phoenix, :live_view, :handle_event, :exception],
        %{},
        %{
          event: "symlink-attempt",
          kind: :error,
          reason: %RuntimeError{message: "no"},
          stacktrace: []
        }
      )

    assert {:error, :symlink} =
             FlightRecorder.persist_report(report, %{overrides | crashes_dir: symlink_dir})
  end

  test "attaches rotating OTP file logger and writes formatted entries to disk", %{
    tmp_dir: tmp_dir
  } do
    import ExUnit.CaptureLog
    require Logger

    log_file = Path.join([tmp_dir, "logs", "dev.log"])
    handler_id = :elixir_canvas_test_file_log

    on_exit(fn ->
      FlightRecorder.detach_file_logger(handler_id)
    end)

    capture_log(fn ->
      assert :ok = FlightRecorder.attach_file_logger(log_file, handler_id)
      marker = "flight-recorder-log-check-#{System.unique_integer([:positive])}"
      Logger.warning(marker, request_id: "req-flight-test")
      :logger_std_h.filesync(handler_id)

      contents = File.read!(log_file)
      assert contents =~ marker
      assert contents =~ "req-flight-test"
    end)
  end
end
