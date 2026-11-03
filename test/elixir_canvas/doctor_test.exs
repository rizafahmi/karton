defmodule ElixirCanvas.DoctorTest do
  use ExUnit.Case, async: true

  alias ElixirCanvas.FlightRecorder
  alias Mix.Tasks.Canvas.Doctor

  @moduletag :tmp_dir

  test "reports healthy status when examples are valid, assets are fresh, and no crashes exist",
       %{tmp_dir: tmp_dir} do
    crashes_dir = Path.join(tmp_dir, "crashes")
    logs_dir = Path.join(tmp_dir, "logs")
    log_file = Path.join(logs_dir, "dev.log")
    examples_dir = Path.join(tmp_dir, "examples")
    File.mkdir_p!(examples_dir)

    File.cp!(
      Path.expand("../../shared/fixtures/v1/document.json", __DIR__),
      Path.join(examples_dir, "ok.json")
    )

    source_js = Path.join(tmp_dir, "source.js")
    built_js = Path.join(tmp_dir, "built.js")
    built_css = Path.join(tmp_dir, "built.css")
    File.write!(source_js, "export const x = 1\n")
    File.write!(built_js, "// built js\n")
    File.write!(built_css, "/* built css */\n")

    compiled_sha = FlightRecorder.runtime_info()["git_sha"]

    report =
      Doctor.collect_report(
        crashes_dir: crashes_dir,
        logs_dir: logs_dir,
        log_file: log_file,
        head_sha: compiled_sha,
        modified_examples: [],
        examples_glob: Path.join(examples_dir, "*.json"),
        source_assets_glob: source_js,
        built_js_path: built_js,
        built_css_path: built_css
      )

    assert report["status"] == "healthy"
    assert report["issues"] == []
    assert report["traceability"]["build_matches_head"] == true
    assert report["traceability"]["assets"]["fresh"] == true
    assert report["examples"]["total"] == 1
    assert report["examples"]["valid_count"] == 1
    assert report["crashes"]["count"] == 0
  end

  test "flags stale build, invalid or modified examples, recorded crashes, and clears crashes safely",
       %{tmp_dir: tmp_dir} do
    crashes_dir = Path.join(tmp_dir, "crashes")
    logs_dir = Path.join(tmp_dir, "logs")
    log_file = Path.join(logs_dir, "dev.log")
    examples_dir = Path.join(tmp_dir, "examples")
    File.mkdir_p!(logs_dir)
    File.mkdir_p!(examples_dir)

    File.write!(
      Path.join(examples_dir, "broken.json"),
      ~s({"version": 2, "nodes": [], "edges": []})
    )

    File.write!(
      log_file,
      "2026-11-02 12:00:00 [info] boot\n2026-11-02 12:00:01 [error] boom in handler\n"
    )

    crash =
      FlightRecorder.build_report(
        [:phoenix, :live_view, :handle_event, :exception],
        %{},
        %{
          event: "save",
          kind: :error,
          reason: %RuntimeError{message: "simulated crash"},
          stacktrace: []
        }
      )

    {:ok, crash_path} =
      FlightRecorder.persist_report(crash, %{
        crashes_dir: crashes_dir,
        logs_dir: logs_dir,
        max_crashes: 10
      })

    assert File.regular?(crash_path)

    report =
      Doctor.collect_report(
        crashes_dir: crashes_dir,
        logs_dir: logs_dir,
        log_file: log_file,
        head_sha: "deadbeef0000",
        modified_examples: ["examples/welcome.json"],
        examples_glob: Path.join(examples_dir, "*.json"),
        source_assets_glob: Path.join(tmp_dir, "*.js"),
        built_js_path: Path.join(tmp_dir, "missing.js"),
        built_css_path: Path.join(tmp_dir, "missing.css")
      )

    assert report["status"] == "attention_needed"
    issue_codes = Enum.map(report["issues"], & &1["code"])
    assert "compiled_build_stale" in issue_codes
    assert "assets_stale_or_missing" in issue_codes
    assert "invalid_examples" in issue_codes
    assert "modified_examples" in issue_codes
    assert "recorded_crashes" in issue_codes

    assert [%{"id" => id, "matches_head" => false}] = report["crashes"]["recent"]
    assert id == crash["id"]

    assert report["logs"]["recent_warnings_and_errors"] == [
             "2026-11-02 12:00:01 [error] boom in handler"
           ]

    assert Doctor.clear_crashes(crashes_dir: crashes_dir, logs_dir: logs_dir) == 1
    assert FlightRecorder.list_crashes(crashes_dir: crashes_dir) == []
    refute File.exists?(Path.join(logs_dir, "crashes.jsonl"))
  end

  test "run/1 supports default human output and --json output without raising when healthy" do
    Mix.shell(Mix.Shell.Process)

    on_exit(fn ->
      Mix.shell(Mix.Shell.IO)
    end)

    report = Doctor.run(["--json"])
    assert is_map(report)
    assert_received {:mix_shell, :info, [json_output]}
    assert {:ok, decoded} = Jason.decode(json_output)
    assert decoded["examples"]["total"] >= 12
  end
end
