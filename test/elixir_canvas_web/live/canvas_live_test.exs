defmodule ElixirCanvasWeb.CanvasLiveTest do
  use ElixirCanvasWeb.ConnCase, async: true

  import Phoenix.LiveViewTest

  alias ElixirCanvas.Document
  alias Hakushi.{Change, Graph}
  alias Hakushi.Test, as: CanvasTest

  @moduletag :tmp_dir

  setup %{conn: conn, tmp_dir: directory} do
    path = Path.join(directory, "portable.json")

    source =
      Path.expand("../../fixtures/document.json", __DIR__)
      |> File.read!()
      |> Jason.decode!()

    File.write!(path, Jason.encode!(source))
    {:ok, view, _html} = live(conn, ~p"/")
    render_submit(view, "open", %{"path" => path})
    %{view: view, path: path, source: source}
  end

  test "selected bytes replace the canvas content and filename without writing the server source",
       %{
         view: view,
         path: path,
         source: source
       } do
    original = File.read!(path)

    selected_source =
      source
      |> Map.put("appearance", %{"font" => "mono", "future" => %{"keep" => true}})
      |> put_in(["nodes", Access.at(0), "x"], -125.5)
      |> put_in(["nodes", Access.at(0), "data", "text"], "Chosen file content")
      |> put_in(["nodes", Access.at(0), "data", "font"], "heading")

    bytes = Jason.encode!(selected_source)
    generation = workspace_integer(view, "data-generation")

    assert %{ok: true, generation: accepted, revision: revision} =
             selected_event(view, "selected-open", %{
               "filename" => "chosen.canvas.json",
               "bytes" => bytes,
               "mode" => "browser_file",
               "generation" => generation
             })

    assert accepted == generation + 1
    assert revision == Base.encode16(:crypto.hash(:sha256, bytes), case: :lower)
    assert page_title(view) == "chosen.canvas.json"
    assert has_element?(view, "#workspace[data-file-mode=browser_file][data-dirty=false]")

    assert has_element?(
             view,
             "#workspace[data-file-name='chosen.canvas.json'][data-drawing-font=mono]"
           )

    assert render(view) =~ "chosen.canvas.json"
    [idea, _make] = CanvasTest.nodes(view, board_id(view))
    assert idea.x == -125.5
    assert idea.label =~ "Chosen file content"

    assert has_element?(
             view,
             "[data-id=idea] .drawing-typography[data-drawing-font=heading]"
           )

    assert File.read!(path) == original
  end

  test "document menu displays app info, tech stack, and GitHub link while AgentRouter referral badge sits in the workspace",
       %{view: view} do
    assert has_element?(
             view,
             "a#agentrouter-badge[href='https://agentrouter.org/register?aff=pWPV']",
             "AgentRouter"
           )

    render_click(view, "toggle-file-menu")

    assert has_element?(view, "#file-menu .about-section", "Elixir Canvas")
    assert has_element?(view, "#file-menu .tech-stack", "Phoenix LiveView")
    assert has_element?(view, "#file-menu .tech-stack", "Hakushi")

    assert has_element?(
             view,
             "#file-menu a[href='https://github.com/rizafahmi/elixir_canvas']",
             "github.com/rizafahmi/elixir_canvas"
           )
  end

  test "invalid selected content and a dirty selected-open preserve the current canvas", %{
    view: view,
    path: path,
    source: source
  } do
    original = File.read!(path)
    board = board_id(view)
    generation = workspace_integer(view, "data-generation")

    valid = %{
      "filename" => "other.json",
      "bytes" => original,
      "mode" => "save_copy",
      "generation" => generation
    }

    for payload <- [
          Map.put(valid, "bytes", "{"),
          Map.delete(valid, "bytes"),
          Map.put(valid, "bytes", %{}),
          Map.put(valid, "filename", ""),
          Map.put(valid, "filename", 42),
          Map.put(valid, "mode", "server_file")
        ] do
      assert %{ok: false} = selected_event(view, "selected-open", payload)
      assert board_id(view) == board
      assert workspace_integer(view, "data-generation") == generation
      assert has_element?(view, "#workspace[data-file-mode=server_file][data-dirty=false]")
      assert hd(CanvasTest.nodes(view, board)).label =~ "Start with an idea"
      assert File.read!(path) == original
    end

    assert :ok = CanvasTest.edit(view, board, "idea", "text", %{"value" => "Unsaved local text"})
    assert has_element?(view, "#workspace[data-dirty=true]")

    replacement =
      put_in(source, ["nodes", Access.at(0), "data", "text"], "Must not replace edits")

    assert %{ok: false} =
             selected_event(view, "selected-open", %{
               "filename" => "other.json",
               "bytes" => Jason.encode!(replacement),
               "mode" => "browser_file",
               "generation" => generation
             })

    assert board_id(view) == board
    assert workspace_integer(view, "data-generation") == generation
    assert hd(CanvasTest.nodes(view, board)).label =~ "Unsaved local text"

    assert File.read!(path) == original
  end

  test "a selected handle save acknowledges only its serialized snapshot while newer edits stay dirty",
       %{view: view, path: path, source: source} do
    original = File.read!(path)

    selected_source =
      source
      |> Map.put("author", %{"keep" => "top-level metadata"})
      |> Map.put("appearance", %{"font" => "sans", "future" => %{"keep" => true}})
      |> Map.put("paper", %{"background" => "dots", "grid" => 20, "annotation" => "Keep paper"})
      |> put_in(["nodes", Access.at(0), "annotation"], %{"keep" => true})
      |> put_in(["nodes", Access.at(0), "data", "font"], "handwritten")
      |> put_in(["edges", Access.at(0), "annotation"], %{"keep" => true})

    opened_bytes = Jason.encode!(selected_source)

    assert %{ok: true, generation: generation} =
             selected_event(view, "selected-open", %{
               "filename" => "selected.json",
               "bytes" => opened_bytes,
               "mode" => "browser_file",
               "generation" => workspace_integer(view, "data-generation")
             })

    board = board_id(view)
    assert :ok = CanvasTest.move(view, board, "idea", {125.5, -90})
    render_change(view, "appearance", %{"font" => "heading"})

    assert %{ok: true, token: token, bytes: bytes} =
             prepared = selected_event(view, "save", %{"generation" => generation})

    assert prepared.revision ==
             Base.encode16(:crypto.hash(:sha256, opened_bytes), case: :lower)

    assert prepared.saved_revision == Base.encode16(:crypto.hash(:sha256, bytes), case: :lower)
    assert {:ok, snapshot} = Document.open_selected("selected.json", bytes, :browser_file)
    assert Document.drawing_font(snapshot) == "heading"
    assert snapshot.source["appearance"]["future"] == %{"keep" => true}
    assert snapshot.source["author"] == selected_source["author"]
    assert snapshot.source["paper"]["annotation"] == "Keep paper"
    assert hd(snapshot.source["nodes"])["annotation"] == %{"keep" => true}
    assert hd(snapshot.source["edges"])["annotation"] == %{"keep" => true}

    assert {Graph.node(snapshot.graph, "idea").x, Graph.node(snapshot.graph, "idea").y} ==
             {125.5, -90}

    assert Graph.node(snapshot.graph, "idea").data["font"] == "handwritten"
    assert has_element?(view, "#workspace[data-dirty=true]")

    assert :ok = CanvasTest.move(view, board, "idea", {350, 70})
    render_change(view, "appearance", %{"font" => "mono"})

    assert %{ok: true} =
             selected_event(view, "selected-saved", %{
               "token" => token,
               "generation" => generation
             })

    assert has_element?(view, "#workspace[data-dirty=true][data-drawing-font=mono]")
    assert node_box(view, board, "idea") == {350, 70, 240, 140}
    assert workspace_integer(view, "data-generation") == generation

    assert %{ok: true, token: next_token, bytes: next_bytes} =
             next_save = selected_event(view, "save", %{"generation" => generation})

    assert next_save.revision == prepared.saved_revision

    assert {:ok, next_snapshot} =
             Document.open_selected("selected.json", next_bytes, :browser_file)

    assert Graph.node(next_snapshot.graph, "idea").x == 350
    assert Document.drawing_font(next_snapshot) == "mono"

    assert %{ok: true} =
             selected_event(view, "selected-saved", %{
               "token" => next_token,
               "generation" => generation
             })

    assert has_element?(view, "#workspace[data-dirty=false][data-drawing-font=mono]")
    assert File.read!(path) == original
  end

  test "a downloaded selected copy stays dirty and can transition back to an explicit server file",
       %{
         view: view,
         path: path,
         source: source,
         tmp_dir: directory
       } do
    original = File.read!(path)

    assert %{ok: true, generation: generation} =
             selected_event(view, "selected-open", %{
               "filename" => "portable.json",
               "bytes" => original,
               "mode" => "save_copy",
               "generation" => workspace_integer(view, "data-generation")
             })

    board = board_id(view)
    assert :ok = CanvasTest.move(view, board, "idea", {260, -50})

    assert %{ok: true, token: token, bytes: bytes} =
             selected_event(view, "save", %{"generation" => generation})

    copy_path = Path.join(directory, "downloaded-copy.json")
    File.write!(copy_path, bytes, [:exclusive])
    assert {:ok, copy} = Document.open(copy_path)
    assert Graph.node(copy.graph, "idea").x == 260
    assert Graph.node(copy.graph, "idea").data["text"] == hd(source["nodes"])["data"]["text"]

    assert %{ok: false} =
             selected_event(view, "selected-saved", %{
               "token" => token,
               "generation" => generation
             })

    assert %{ok: true} =
             selected_event(view, "selected-copy-downloaded", %{
               "token" => token,
               "generation" => generation
             })

    assert has_element?(view, "#workspace[data-file-mode=save_copy][data-dirty=true]")
    assert has_element?(view, "#file-notice[role=status]")
    assert File.read!(path) == original

    assert %{ok: true} =
             selected_event(view, "selected-reload", %{
               "filename" => "portable.json",
               "bytes" => File.read!(path),
               "mode" => "save_copy",
               "generation" => generation,
               "edit_version" => workspace_integer(view, "data-edit-version")
             })

    assert has_element?(view, "#workspace[data-file-mode=save_copy][data-dirty=false]")
    assert node_box(view, board_id(view), "idea") == {0, 0, 240, 140}
    render_submit(view, "open", %{"path" => copy_path})
    assert has_element?(view, "#workspace[data-file-mode=server_file][data-dirty=false]")
    assert :ok = CanvasTest.move(view, board_id(view), "idea", {500, 80})
    assert %{ok: true} = selected_event(view, "save", %{})
    assert {:ok, saved_copy} = Document.open(copy_path)
    assert Graph.node(saved_copy.graph, "idea").x == 500
    assert File.read!(path) == original
  end

  test "selected reload rejects a read overtaken by edits and accepts fresh selected content", %{
    view: view,
    path: path,
    source: source
  } do
    original = File.read!(path)

    assert %{ok: true, generation: generation} =
             selected_event(view, "selected-open", %{
               "filename" => "picked.json",
               "bytes" => original,
               "mode" => "browser_file",
               "generation" => workspace_integer(view, "data-generation")
             })

    board = board_id(view)
    assert :ok = CanvasTest.move(view, board, "idea", {175, -40})
    read_version = workspace_integer(view, "data-edit-version")
    render_change(view, "appearance", %{"font" => "heading"})
    external = put_in(source, ["nodes", Access.at(0), "data", "text"], "Fresh handle contents")

    reload = %{
      "filename" => "picked.json",
      "bytes" => Jason.encode!(external),
      "mode" => "browser_file",
      "generation" => generation,
      "edit_version" => read_version
    }

    assert %{ok: false} = selected_event(view, "selected-reload", reload)
    assert has_element?(view, "#workspace[data-dirty=true][data-drawing-font=heading]")
    assert node_box(view, board, "idea") == {175, -40, 240, 140}

    assert %{ok: true} =
             selected_event(view, "selected-reload", %{
               reload
               | "edit_version" => workspace_integer(view, "data-edit-version")
             })

    assert has_element?(view, "#workspace[data-file-mode=browser_file][data-dirty=false]")
    assert hd(CanvasTest.nodes(view, board_id(view))).label =~ "Fresh handle contents"

    assert File.read!(path) == original
  end

  test "failed and mismatched selected saves preserve edits and cannot acknowledge another source",
       %{
         view: view,
         path: path
       } do
    original = File.read!(path)

    assert %{ok: true, generation: generation} =
             selected_event(view, "selected-open", %{
               "filename" => "selected.json",
               "bytes" => original,
               "mode" => "browser_file",
               "generation" => workspace_integer(view, "data-generation")
             })

    assert :ok = CanvasTest.move(view, board_id(view), "idea", {220, -25})

    assert %{ok: true, token: token} =
             selected_event(view, "save", %{"generation" => generation})

    assert %{ok: false} =
             selected_event(view, "selected-saved", %{
               "token" => "not-the-prepared-token",
               "generation" => generation
             })

    render_submit(view, "open", %{"path" => path})
    assert has_element?(view, "#workspace[data-file-mode=browser_file][data-dirty=true]")

    assert %{ok: false} =
             selected_event(view, "selected-save-error", %{
               "token" => token,
               "generation" => generation,
               "message" => "File changed on disk. Nothing was overwritten.",
               "status" => "changed"
             })

    assert has_element?(view, "#workspace[data-dirty=true]")
    assert node_box(view, board_id(view), "idea") == {220, -25, 240, 140}
    assert has_element?(view, "#disk-warning[role=status]")
    assert File.read!(path) == original

    assert %{ok: true} =
             selected_event(view, "selected-reload", %{
               "filename" => "selected.json",
               "bytes" => original,
               "mode" => "browser_file",
               "generation" => generation,
               "edit_version" => workspace_integer(view, "data-edit-version")
             })

    render_submit(view, "open", %{"path" => path})

    assert %{ok: false} =
             selected_event(view, "selected-saved", %{
               "token" => token,
               "generation" => generation
             })

    assert has_element?(view, "#workspace[data-file-mode=server_file][data-dirty=false]")
    assert File.read!(path) == original
  end

  test "opening an implicit sans document stays clean and saving does not add appearance", %{
    view: view,
    path: path
  } do
    bytes = File.read!(path)
    assert has_element?(view, "[data-dirty=false][data-drawing-font=sans]")
    assert File.read!(path) == bytes

    assert %{ok: true} = selected_event(view, "save", %{})
    {:ok, document} = Document.open(path)
    refute Map.has_key?(document.source, "appearance")
    assert has_element?(view, "[data-dirty=false][data-drawing-font=sans]")
  end

  test "all generic lettering choices are explicit edits that preserve geometry and metadata", %{
    view: view,
    path: path,
    source: source
  } do
    source = Map.put(source, "appearance", %{"font" => "sans", "future" => %{"keep" => true}})
    File.write!(path, Jason.encode!(source))
    render_click(view, "reload")
    render_click(view, "toggle-file-menu")

    {:ok, original} = Document.open(path)

    for font <- ~w(heading mono handwritten sans) do
      view |> form("#appearance-form", %{"font" => font}) |> render_change()
      assert has_element?(view, "[data-dirty=true][data-drawing-font=#{font}]")
      assert has_element?(view, "#drawing-font option[value=#{font}][selected]")
      {:ok, before_save} = Document.open(path)
      refute Document.drawing_font(before_save) == font

      assert %{ok: true} = selected_event(view, "save", %{})
      assert has_element?(view, "[data-dirty=false][data-drawing-font=#{font}]")
      {:ok, saved} = Document.open(path)
      assert saved.source["appearance"] == %{"font" => font, "future" => %{"keep" => true}}
      assert saved.graph == original.graph

      render_click(view, "reload")
      assert has_element?(view, "[data-dirty=false][data-drawing-font=#{font}]")
      render_click(view, "toggle-file-menu")
    end
  end

  test "reverting lettering clears only the lettering edit, not graph edits", %{
    view: view,
    path: path
  } do
    render_change(view, "appearance", %{"font" => "heading"})
    assert has_element?(view, "[data-dirty=true]")
    render_change(view, "appearance", %{"font" => "sans"})
    assert has_element?(view, "[data-dirty=false]")

    {:ok, document} = Document.open(path)

    {:ok, graph, _, _} =
      Graph.apply(document.graph, Change.move([%{id: "idea", x: 123.5, y: -90}]))

    send(view.pid, {:canvas_changed, graph})
    assert has_element?(view, "[data-dirty=true]")
    render_change(view, "appearance", %{"font" => "mono"})
    render_change(view, "appearance", %{"font" => "sans"})
    assert has_element?(view, "[data-dirty=true][data-drawing-font=sans]")
  end

  test "document lettering changes leave explicit object roles and inherited data untouched", %{
    view: view,
    path: path,
    source: source
  } do
    source =
      source
      |> Map.put("appearance", %{"font" => "handwritten", "future" => %{"keep" => true}})
      |> put_in(["nodes", Access.at(0), "data", "font"], "sans")

    File.write!(path, Jason.encode!(source))
    render_click(view, "reload")
    assert {:ok, original} = Document.open(path)

    for font <- ~w(mono heading handwritten sans) do
      render_change(view, "appearance", %{"font" => font})
      assert %{ok: true} = selected_event(view, "save", %{})
      render_click(view, "reload")
      assert {:ok, reopened} = Document.open(path)
      assert Document.drawing_font(reopened) == font
      assert reopened.graph == original.graph
      assert Graph.node(reopened.graph, "idea").data["font"] == "sans"
      refute Map.has_key?(Graph.node(reopened.graph, "make").data, "font")
      assert reopened.source["appearance"]["future"] == %{"keep" => true}
    end
  end

  test "selection typography applies as one undoable edit without changing geometry",
       %{
         view: view,
         path: path,
         source: source
       } do
    line = %{
      "id" => "line",
      "type" => "shape-line",
      "x" => 20,
      "y" => 220,
      "width" => 220,
      "height" => 100,
      "data" => %{"from" => [12, 12], "to" => [208, 88], "stroke" => "surface", "arrow" => "both"}
    }

    source =
      source
      |> Map.put("appearance", %{"font" => "handwritten", "future" => %{"keep" => true}})
      |> put_in(["nodes", Access.at(0), "data", "font"], "sans")
      |> put_in(["nodes", Access.at(0), "data", "future"], %{"keep" => true})
      |> put_in(["nodes", Access.at(1), "data", "kind"], "text")
      |> Map.update!("nodes", &(&1 ++ [line]))

    File.write!(path, Jason.encode!(source))
    render_click(view, "reload")
    board = board_id(view)
    assert {:ok, original} = Document.open(path)
    selected = ["idea", "make", "line"]

    assert :ok =
             CanvasTest.edit(view, board, selected, "style", %{"style" => %{"font" => "mono"}})

    assert has_element?(view, "[data-dirty=true]")
    assert :ok = CanvasTest.undo(view, board)
    assert has_element?(view, "[data-dirty=false]")
    assert :ok = CanvasTest.redo(view, board)
    assert %{ok: true} = selected_event(view, "save", %{})
    assert {:ok, overridden} = Document.open(path)

    for id <- ~w(idea make) do
      authored = Graph.node(original.graph, id)
      expected = %{authored | data: Map.put(authored.data, "font", "mono")}
      assert Graph.node(overridden.graph, id) == expected
    end

    assert Graph.node(overridden.graph, "line") == Graph.node(original.graph, "line")
    assert overridden.graph.edges == original.graph.edges
    assert overridden.source["appearance"] == original.source["appearance"]
  end

  test "object role changes preserve true text-edit growth, undo, save, and reload", %{
    view: view,
    path: path,
    source: source
  } do
    source =
      source
      |> put_in(["nodes", Access.at(1), "data", "kind"], "text")
      |> put_in(["nodes", Access.at(1), "data", "font"], "handwritten")

    File.write!(path, Jason.encode!(source))
    render_click(view, "reload")
    board = board_id(view)
    assert {:ok, document} = Document.open(path)
    original = Graph.node(document.graph, "make")
    initial_box = {original.x, original.y, original.width, original.height}
    text = "First line\nSecond line\nThird line"
    grown_box = [original.x, original.y, original.width + 20, original.height + 80]

    assert :ok =
             CanvasTest.edit(view, board, "make", "style", %{"style" => %{"font" => "heading"}})

    assert node_box(view, board, "make") == initial_box

    assert :ok =
             CanvasTest.edit(view, board, "make", "text", %{"value" => text, "box" => grown_box})

    assert node_box(view, board, "make") == List.to_tuple(grown_box)
    assert :ok = CanvasTest.undo(view, board)
    assert node_box(view, board, "make") == initial_box
    assert :ok = CanvasTest.undo(view, board)
    assert has_element?(view, "[data-dirty=false]")
    assert :ok = CanvasTest.redo(view, board)
    assert node_box(view, board, "make") == initial_box
    assert :ok = CanvasTest.redo(view, board)
    assert node_box(view, board, "make") == List.to_tuple(grown_box)

    assert %{ok: true} = selected_event(view, "save", %{})
    render_click(view, "reload")
    assert {:ok, reopened} = Document.open(path)
    edited = Graph.node(reopened.graph, "make")
    assert {edited.x, edited.y, edited.width, edited.height} == List.to_tuple(grown_box)
    expected_data = original.data |> Map.put("font", "heading") |> Map.put("text", text)
    assert edited.data == expected_data
    assert node_box(view, board_id(view), "make") == List.to_tuple(grown_box)
  end

  test "endpoint edits cross direction atomically and reject an invalid box", %{
    view: view,
    path: path,
    source: source
  } do
    line = %{
      "id" => "line",
      "type" => "shape-line",
      "x" => 20.25,
      "y" => 220.125,
      "width" => 220,
      "height" => 100,
      "data" => %{
        "from" => [208.375, 88.125],
        "to" => [12.125, 12.625],
        "stroke" => "surface",
        "arrow" => "both",
        "future" => %{"keep" => true}
      }
    }

    source = Map.update!(source, "nodes", &(&1 ++ [line]))
    File.write!(path, Jason.encode!(source))
    render_click(view, "reload")
    board = board_id(view)
    assert {:ok, original} = Document.open(path)
    before = Graph.node(original.graph, "line")

    params = %{
      "from" => [12.125, 12.25],
      "to" => [182.375, 124.75],
      "box" => [-150, 108, 194.4, 148.8]
    }

    assert :ok = CanvasTest.edit(view, board, "line", "endpoints", params)
    assert node_box(view, board, "line") == {-150, 108, 194.4, 148.8}
    assert :ok = CanvasTest.undo(view, board)
    assert node_box(view, board, "line") == {before.x, before.y, before.width, before.height}
    assert has_element?(view, "[data-dirty=false]")
    assert :ok = CanvasTest.redo(view, board)
    assert %{ok: true} = selected_event(view, "save", %{})
    assert {:ok, saved} = Document.open(path)
    after_edit = Graph.node(saved.graph, "line")
    assert after_edit.data == Map.merge(before.data, Map.take(params, ["from", "to"]))
    [tx, ty] = after_edit.data["to"]
    [original_tx, original_ty] = before.data["to"]
    assert after_edit.x + tx == before.x + original_tx
    assert after_edit.y + ty == before.y + original_ty
    assert saved.graph.edges == original.graph.edges

    for box <- [nil, [0, 0, 0, 100], [0, 0, 100, -1], [0, 0, "wide", 100]] do
      invalid = %{params | "from" => [200, 200], "box" => box}
      assert {:error, _reason} = CanvasTest.edit(view, board, "line", "endpoints", invalid)
      assert has_element?(view, "[data-dirty=false]")
    end

    render_click(view, "reload")
    assert node_box(view, board_id(view), "line") == {-150, 108, 194.4, 148.8}
  end

  test "same-node arrows require different named handles and survive undo and saving", %{
    view: view,
    path: path
  } do
    board = board_id(view)
    initial_edges = CanvasTest.edges(view, board)

    for handle <- ~w(top right bottom left) do
      assert {:error, _reason} =
               CanvasTest.connect(view, board, {"idea", handle}, {"idea", handle})
    end

    assert CanvasTest.edges(view, board) == initial_edges
    assert has_element?(view, "[data-dirty=false]")

    assert :ok = CanvasTest.connect(view, board, {"idea", "right"}, {"idea", "top"})
    [loop] = CanvasTest.edges(view, board) -- initial_edges

    assert {loop.source, loop.source_handle, loop.target, loop.target_handle} ==
             {"idea", "right", "idea", "top"}

    assert {:error, _reason} =
             CanvasTest.reconnect(view, board, loop.id, target: {"idea", "right"})

    assert loop in CanvasTest.edges(view, board)
    assert :ok = CanvasTest.undo(view, board)
    assert CanvasTest.edges(view, board) == initial_edges
    assert has_element?(view, "[data-dirty=false]")
    assert :ok = CanvasTest.redo(view, board)
    assert loop in CanvasTest.edges(view, board)

    assert %{ok: true} = selected_event(view, "save", %{})
    assert {:ok, saved} = Document.open(path)
    saved_loop = Graph.edge(saved.graph, loop.id)

    assert {saved_loop.source, saved_loop.source_handle, saved_loop.target,
            saved_loop.target_handle} == {"idea", "right", "idea", "top"}

    render_click(view, "reload")
    board = board_id(view)
    assert loop in CanvasTest.edges(view, board)
    assert :ok = CanvasTest.remove(view, board, edges: [loop.id])
    refute Enum.any?(CanvasTest.edges(view, board), &(&1.id == loop.id))
    assert :ok = CanvasTest.undo(view, board)
    assert loop in CanvasTest.edges(view, board)
  end

  test "geometry and reconnect preserve authored metadata through save and history",
       %{
         view: view,
         path: path,
         source: source
       } do
    source =
      source
      |> put_in(["nodes", Access.at(0), "data", "future"], %{"keep" => [1, 2]})
      |> put_in(["edges", Access.at(0), "data"], %{"future" => "keep"})
      |> put_in(["edges", Access.at(0), "path"], "step")
      |> put_in(["edges", Access.at(0), "marker"], "dot")

    File.write!(path, Jason.encode!(source))
    render_click(view, "reload")
    board = board_id(view)
    original_box = node_box(view, board, "idea")
    original_edge = hd(CanvasTest.edges(view, board))

    assert :ok =
             CanvasTest.edit(view, board, "idea", "rotate", %{
               "value" => 45,
               "box" => [-12.5, 42, 190, 85]
             })

    assert node_box(view, board, "idea") == {-12.5, 42, 190, 85}
    assert :ok = CanvasTest.undo(view, board)
    assert node_box(view, board, "idea") == original_box
    assert :ok = CanvasTest.redo(view, board)

    assert :ok =
             CanvasTest.reconnect(view, board, original_edge.id,
               source: {"idea", "bottom"},
               target: {"idea", "top"}
             )

    assert :ok = CanvasTest.label(view, board, original_edge.id, "Return")
    assert %{ok: true} = selected_event(view, "save", %{})
    assert {:ok, saved} = Document.open(path)
    node = Graph.node(saved.graph, "idea")
    assert node.data["future"] == %{"keep" => [1, 2]}
    assert node.data["rotation"] == 45
    edge = Graph.edge(saved.graph, original_edge.id)

    assert {edge.source, edge.source_handle, edge.target, edge.target_handle} ==
             {"idea", "bottom", "idea", "top"}

    assert {edge.path, edge.marker, edge.label, edge.data} ==
             {"step", "dot", "Return", %{"future" => "keep"}}

    assert :ok = CanvasTest.undo(view, board)
    assert :ok = CanvasTest.undo(view, board)
    assert hd(CanvasTest.edges(view, board)) == original_edge
  end

  test "stacking is one history action and saves only node order", %{
    view: view,
    path: path,
    source: source
  } do
    [idea, make] = Enum.map(source["nodes"], &Map.put(&1, "locked", false))
    third = idea |> Map.put("id", "third") |> Map.put("future", %{"keep" => [1, 2]})
    fourth = make |> Map.put("id", "fourth") |> Map.put("locked", true)
    source = Map.put(source, "nodes", [idea, make, third, fourth])
    File.write!(path, Jason.encode!(source))
    {:ok, original_document} = Document.open(path)
    expected = original_document |> Document.encode(original_document.graph) |> Jason.decode!()
    render_click(view, "reload")
    board = board_id(view)
    original = ~w(idea make third fourth)
    order = fn -> Enum.map(CanvasTest.nodes(view, board), & &1.id) end

    stack(view, board, "front", ~w(third idea))
    assert order.() == ~w(make fourth idea third)
    assert has_element?(view, "#workspace[data-dirty=true]")
    assert :ok = CanvasTest.undo(view, board)
    assert order.() == original
    assert has_element?(view, "#workspace[data-dirty=false]")
    assert :ok = CanvasTest.redo(view, board)
    assert order.() == ~w(make fourth idea third)

    stack(view, board, "back", ~w(third idea))
    assert order.() == ~w(idea third make fourth)
    assert :ok = CanvasTest.undo(view, board)
    assert order.() == ~w(make fourth idea third)
    assert :ok = CanvasTest.redo(view, board)
    assert order.() == ~w(idea third make fourth)

    assert %{ok: true} = selected_event(view, "save", %{})
    saved = path |> File.read!() |> Jason.decode!()
    assert Enum.map(saved["nodes"], & &1["id"]) == ~w(idea third make fourth)

    assert Map.new(saved["nodes"], &{&1["id"], &1}) ==
             Map.new(expected["nodes"], &{&1["id"], &1})

    assert Map.delete(saved, "nodes") == Map.delete(expected, "nodes")
    render_click(view, "reload")
    assert Enum.map(CanvasTest.nodes(view, board_id(view)), & &1.id) == ~w(idea third make fourth)
  end

  test "stacking no-ops preserve clean state and redo across ordinary edits", %{
    view: view,
    path: path
  } do
    board = board_id(view)
    version = workspace_integer(view, "data-edit-version")

    for {direction, ids} <- [{"front", []}, {"back", []}, {"front", ["make"]}, {"back", ["idea"]}] do
      stack(view, board, direction, ids)
    end

    assert workspace_integer(view, "data-edit-version") == version
    assert has_element?(view, "#workspace[data-dirty=false]")
    assert {:error, _} = CanvasTest.undo(view, board)

    assert :ok = CanvasTest.move(view, board, "idea", {25, 30})
    stack(view, board, "front", ["idea"])
    assert :ok = CanvasTest.move(view, board, "make", {450, 50})
    assert :ok = CanvasTest.undo(view, board)
    assert node_box(view, board, "make") == {400, 0, 240, 140}
    assert :ok = CanvasTest.undo(view, board)
    assert Enum.map(CanvasTest.nodes(view, board), & &1.id) == ~w(idea make)
    assert :ok = CanvasTest.undo(view, board)
    assert has_element?(view, "#workspace[data-dirty=false]")

    version = workspace_integer(view, "data-edit-version")
    stack(view, board, "front", ["make"])
    stack(view, board, "back", [])
    assert workspace_integer(view, "data-edit-version") == version
    assert :ok = CanvasTest.redo(view, board)
    assert node_box(view, board, "idea") == {25, 30, 240, 140}
    assert :ok = CanvasTest.redo(view, board)
    assert Enum.map(CanvasTest.nodes(view, board), & &1.id) == ~w(make idea)
    assert :ok = CanvasTest.redo(view, board)
    assert node_box(view, board, "make") == {450, 50, 240, 140}

    assert %{ok: true} = selected_event(view, "save", %{})
    bytes = File.read!(path)
    stack(view, board, "front", ["idea"])
    assert has_element?(view, "#workspace[data-dirty=false]")
    assert File.read!(path) == bytes
  end

  test "locked and unknown nodes cannot be reordered", %{view: view, path: path, source: source} do
    source = put_in(source, ["nodes", Access.at(0), "locked"], true)
    File.write!(path, Jason.encode!(source))
    render_click(view, "reload")
    board = board_id(view)
    version = workspace_integer(view, "data-edit-version")
    stack(view, board, "front", ~w(idea missing))
    assert Enum.map(CanvasTest.nodes(view, board), & &1.id) == ~w(idea make)
    assert workspace_integer(view, "data-edit-version") == version
    assert has_element?(view, "#workspace[data-dirty=false]")
    assert {:error, _} = CanvasTest.undo(view, board)
  end

  test "a thought's authored text and grown box add atomically with stable redo identity and unchanged source",
       %{view: view, path: path, source: source} do
    source =
      source
      |> put_in(["nodes", Access.at(0), "data", "rotation"], 37)
      |> put_in(["nodes", Access.at(0), "data", "font"], "mono")
      |> put_in(["nodes", Access.at(0), "data", "future"], %{"identity" => ["keep"]})

    File.write!(path, Jason.encode!(source))
    render_click(view, "reload")
    board = board_id(view)
    assert {:ok, original} = Document.open(path)
    initial_nodes = CanvasTest.nodes(view, board)
    text = String.duplicate("👩🏽‍💻", 1_999) <> "\n"

    view
    |> element("##{board}-hook")
    |> render_hook("hakushi:draw", %{
      "tool" => "drawing:rect",
      "box" => [752.4, -120, 160, 640],
      "style" => %{"text" => text}
    })

    %{proxy: {ref, _topic, _pid}} = view

    id =
      receive do
        {^ref, {:reply, %{"ok" => true, "drawn" => id}}} -> id
      after
        1_000 -> flunk("thought draw did not reply")
      end

    [thought] = CanvasTest.nodes(view, board) -- initial_nodes
    assert thought.id == id
    assert node_box(view, board, id) == {752.4, -120, 160, 640}

    assert view
           |> render()
           |> LazyHTML.from_fragment()
           |> LazyHTML.query("[data-id='#{id}'] [data-hakushi-text]")
           |> LazyHTML.attribute("data-hakushi-text") == [text]

    assert has_element?(view, "#workspace[data-dirty=true]")
    assert :ok = CanvasTest.undo(view, board)
    assert CanvasTest.nodes(view, board) == initial_nodes
    assert has_element?(view, "#workspace[data-dirty=false]")
    assert :ok = CanvasTest.redo(view, board)
    assert Enum.find(CanvasTest.nodes(view, board), &(&1.id == id)) == thought
    assert %{ok: true} = selected_event(view, "save", %{})
    assert {:ok, saved} = Document.open(path)
    created = Graph.node(saved.graph, id)
    assert created.data["text"] == text
    assert created.data["kind"] == "rect"
    assert created.data["rotation"] == 0
    refute Map.has_key?(created.data, "font")
    refute Map.has_key?(created.data, "future")
    refute created.locked

    for node <- Graph.nodes(original.graph) do
      assert Graph.node(saved.graph, node.id) == node
    end

    assert saved.graph.edges == original.graph.edges
    render_click(view, "reload")
    assert node_box(view, board_id(view), id) == {752.4, -120, 160, 640}
  end

  test "connector styles preserve metadata, bindings and shared history through save/reopen",
       %{view: view, path: path, source: source} do
    [edge] = source["edges"]
    edge = Map.put(edge, "data", %{"width" => "application", "future" => [1, 2]})
    loop = edge |> Map.put("id", "loop") |> Map.put("target", edge["source"])
    loop = Map.merge(loop, %{"source_handle" => "right", "target_handle" => "top"})
    source = Map.put(source, "edges", [edge, loop])
    File.write!(path, Jason.encode!(source))
    render_click(view, "reload")
    board = board_id(view)
    ids = [edge["id"], "loop"]
    version = workspace_integer(view, "data-edit-version")

    assert %{"ok" => true} = connector_style(view, board, ids, "width", 2)
    assert workspace_integer(view, "data-edit-version") == version
    assert %{"ok" => true} = connector_style(view, board, ids, "stroke", "ink")
    assert has_element?(view, "#workspace[data-dirty=true]")
    ink_version = workspace_integer(view, "data-edit-version")
    assert %{"ok" => true} = connector_style(view, board, ids, "stroke", "ink")
    assert workspace_integer(view, "data-edit-version") == ink_version
    assert :ok = CanvasTest.undo(view, board)
    assert has_element?(view, "#workspace[data-dirty=false]")
    assert %{"ok" => true} = connector_style(view, board, ids, "stroke", "red")
    assert %{"ok" => true} = connector_style(view, board, ids, "width", 4)
    assert %{"ok" => true} = connector_style(view, board, ids, "dash", true)
    assert :ok = CanvasTest.move(view, board, edge["source"], {50, 60})
    assert :ok = CanvasTest.undo(view, board)
    assert :ok = CanvasTest.undo(view, board)
    assert %{ok: true} = selected_event(view, "save", %{})
    assert {:ok, undone} = Document.open(path)

    assert Graph.edge(undone.graph, edge["id"]).data ==
             Map.put(edge["data"], "connector_style", %{"stroke" => "red", "width" => 4})

    assert %{"ok" => true} = connector_style(view, board, ids, "width", 4)
    assert :ok = CanvasTest.redo(view, board)
    assert %{ok: true} = selected_event(view, "save", %{})
    assert {:ok, saved} = Document.open(path)

    for id <- ids do
      styled = Graph.edge(saved.graph, id)

      assert styled.data == %{
               "width" => "application",
               "future" => [1, 2],
               "connector_style" => %{"stroke" => "red", "width" => 4, "dash" => true}
             }

      original = Enum.find(source["edges"], &(&1["id"] == id))
      assert styled.source == original["source"]
      assert styled.target == original["target"]
    end

    assert Graph.edge(saved.graph, "loop").source_handle == "right"
    assert Graph.edge(saved.graph, "loop").target_handle == "top"
    assert saved.source["version"] == 1
    render_click(view, "reload")
    assert {:ok, reopened} = Document.open(path)
    assert reopened.graph == saved.graph
  end

  test "connector collision is atomic and unsupported metadata survives single-property editing",
       %{view: view, path: path, source: source} do
    [edge] = source["edges"]

    good =
      Map.put(edge, "data", %{
        "connector_style" => %{"stroke" => "future-color", "width" => 99, "future" => [3]},
        "application" => true
      })

    collision = good |> Map.put("id", "collision") |> Map.put("data", %{"connector_style" => nil})
    File.write!(path, Jason.encode!(Map.put(source, "edges", [good, collision])))
    render_click(view, "reload")
    board = board_id(view)
    version = workspace_integer(view, "data-edit-version")

    assert %{"error" => _} =
             connector_style(view, board, [good["id"], "collision"], "width", 4)

    assert workspace_integer(view, "data-edit-version") == version
    assert %{"ok" => true} = connector_style(view, board, [good["id"]], "dash", true)
    assert %{ok: true} = selected_event(view, "save", %{})
    assert {:ok, saved} = Document.open(path)

    assert Graph.edge(saved.graph, good["id"]).data ==
             put_in(good["data"], ["connector_style", "dash"], true)

    assert Graph.edge(saved.graph, "collision").data == collision["data"]
    version = workspace_integer(view, "data-edit-version")
    assert %{"ok" => true} = connector_style(view, board, [good["id"]], "dash", true)
    assert workspace_integer(view, "data-edit-version") == version
    assert :ok = CanvasTest.undo(view, board)
    assert %{ok: true} = selected_event(view, "save", %{})
    assert {:ok, undone} = Document.open(path)
    assert Graph.edge(undone.graph, good["id"]).data == good["data"]
    assert :ok = CanvasTest.redo(view, board)
  end

  test "connector style commands reject readonly without changing graph or history",
       %{source: source} do
    graph = Graph.load(source)
    [edge] = Graph.edges(graph)

    socket = %Phoenix.LiveView.Socket{
      assigns: %{
        __changed__: %{},
        graph: graph,
        readonly: true,
        undo: [:existing_undo],
        redo: [:existing_redo]
      }
    }

    assert {:reply, %{"error" => _}, ^socket} =
             ElixirCanvasWeb.DrawingCanvas.handle_event(
               "drawing:edge-style",
               %{"edges" => [edge.id], "key" => "width", "value" => 4},
               socket
             )
  end

  defp connector_style(view, board, ids, key, value) do
    view
    |> element("##{board}-hook")
    |> render_hook("drawing:edge-style", %{"edges" => ids, "key" => key, "value" => value})

    %{proxy: {ref, _topic, _pid}} = view

    reply =
      receive do
        {^ref, {:reply, reply}} -> reply
      after
        1_000 -> flunk("connector style command did not reply")
      end

    render(view)
    reply
  end

  defp stack(view, board, direction, ids) do
    view
    |> element("##{board}-hook")
    |> render_hook("drawing:stack", %{"direction" => direction, "nodes" => ids})

    %{proxy: {ref, _topic, _pid}} = view

    receive do
      {^ref, {:reply, reply}} -> assert reply["ok"]
    after
      1_000 -> flunk("stacking command did not reply")
    end

    render(view)
  end

  defp board_id(view) do
    view
    |> render()
    |> LazyHTML.from_fragment()
    |> LazyHTML.query(".drawing-board")
    |> LazyHTML.attribute("id")
    |> List.first()
  end

  defp node_box(view, board, id) do
    node = view |> CanvasTest.nodes(board) |> Enum.find(&(&1.id == id))
    {node.x, node.y, node.width, node.height}
  end

  defp workspace_integer(view, attribute) do
    view
    |> render()
    |> LazyHTML.from_fragment()
    |> LazyHTML.query("#workspace")
    |> LazyHTML.attribute(attribute)
    |> List.first()
    |> String.to_integer()
  end

  defp selected_event(view, event, payload) do
    render(view)
    view |> element("#workspace") |> render_hook(event, payload)
    %{proxy: {ref, _topic, _pid}} = view

    receive do
      {^ref, {:reply, reply}} -> reply
    after
      1_000 -> flunk("selected file event #{event} did not reply")
    end
  end
end
