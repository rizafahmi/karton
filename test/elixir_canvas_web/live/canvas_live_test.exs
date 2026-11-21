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
      Path.expand("../../../shared/fixtures/v1/document.json", __DIR__)
      |> File.read!()
      |> Jason.decode!()

    File.write!(path, Jason.encode!(source))
    {:ok, view, _html} = live(conn, ~p"/")
    render_submit(view, "open", %{"path" => path})
    %{view: view, path: path, source: source}
  end

  test "code preserves literal source and metadata with a single source-and-box history entry and save reload",
       %{view: view, path: path, source: source} do
    literal = "\uFEFF\t" <> String.duplicate("λ = 1\r\n", 500) <> "\rtrail  \n"

    code = %{
      "id" => "literal",
      "type" => "code",
      "x" => 20,
      "y" => 30,
      "width" => 480,
      "height" => 240,
      "data" => %{"content" => literal, "language" => "elixir", "custom" => %{"keep" => true}}
    }

    File.write!(
      path,
      Jason.encode!(source |> Map.put("version", 2) |> Map.update!("nodes", &(&1 ++ [code])))
    )

    render_click(view, "reload")
    board = board_id(view)
    updated = literal <> "\t  "

    assert :ok =
             CanvasTest.edit(view, board, "literal", "source", %{
               "content" => updated,
               "language" => "plaintext",
               "box" => [40, 50, 600, 300]
             })

    render(view)
    node = Graph.node(copy_state(view).graph, "literal")
    assert node.data["content"] == updated
    assert node.data["custom"] == %{"keep" => true}
    assert node_box(view, board, "literal") == {40, 50, 600, 300}
    assert :ok = CanvasTest.undo(view, board)
    assert Graph.node(copy_state(view).graph, "literal").data["content"] == literal
    assert node_box(view, board, "literal") == {20, 30, 480, 240}
    assert :ok = CanvasTest.redo(view, board)
    assert %{ok: true} = selected_event(view, "save", %{})
    assert {:ok, saved} = Document.open(path)
    assert Graph.node(saved.graph, "literal").data["content"] == updated
    assert Graph.node(saved.graph, "literal").data["custom"] == %{"keep" => true}
    render_click(view, "reload")
    assert Graph.node(copy_state(view).graph, "literal").data["content"] == updated
  end

  test "version-copy is download-only and preserves errors, conflict state, newer edits and history",
       %{view: view, path: path} do
    original = File.read!(path)

    for mode <- [:server_file, :browser_file, :save_copy] do
      if mode != :server_file do
        assert %{ok: true} =
                 selected_event(view, "selected-open", %{
                   "generation" => workspace_integer(view, "data-generation"),
                   "filename" => "legacy.json",
                   "bytes" => original,
                   "mode" => Atom.to_string(mode)
                 })
      end

      board = board_id(view)
      generation = workspace_integer(view, "data-generation")
      assert :ok = CanvasTest.move(view, board, "idea", {310, 75})

      render_click(view, "selected-error", %{
        "generation" => generation,
        "message" => "Source write failed."
      })

      before_copy = copy_state(view)

      assert %{ok: true, token: token, bytes: bytes, filename: filename} =
               selected_event(view, "version-copy", %{"generation" => generation})

      assert String.ends_with?(filename, "-v2.karton")
      assert Jason.decode!(bytes)["version"] == 2
      assert copy_state(view) == before_copy
      assert %{ok: false} = selected_event(view, "version-copy", %{"generation" => generation})

      assert %{ok: false} =
               selected_event(view, "selected-version-copy-downloaded", %{
                 "generation" => generation,
                 "token" => "stale"
               })

      assert :ok = CanvasTest.move(view, board, "idea", {320, 85})
      newer = copy_state(view)

      assert %{ok: true} =
               selected_event(view, "selected-version-copy-downloaded", %{
                 "generation" => generation,
                 "token" => token
               })

      assert copy_state(view) == newer
      assert :sys.get_state(view.pid).socket.assigns.error == "Source write failed."
      assert :ok = CanvasTest.undo(view, board)
      assert node_box(view, board, "idea") |> elem(0) == 310
      assert :ok = CanvasTest.undo(view, board)
      refute copy_state(view).dirty
      assert File.read!(path) == original
    end
  end

  test "native code drawing commits final source once with undo, redo and real save", %{
    view: view,
    path: path,
    source: source
  } do
    File.write!(path, Jason.encode!(Map.put(source, "version", 2)))
    render_submit(view, "open", %{"path" => path})
    board = board_id(view)
    literal = "const café = \"😀\";\r\n\t// source stays literal\r"

    view
    |> element("##{board}-hook")
    |> render_hook("hakushi:draw", %{
      "tool" => "code:block",
      "box" => [500, 250, 320, 180],
      "style" => %{"content" => literal, "language" => "auto"}
    })

    %{proxy: {ref, _topic, _pid}} = view
    assert_receive {^ref, {:reply, %{"ok" => true, "drawn" => drawn_id}}}

    graph = :sys.get_state(view.pid).socket.assigns.graph
    [code] = Enum.filter(Graph.nodes(graph), &(&1.type == "code"))
    assert code.id == drawn_id
    assert code.data["content"] == literal
    assert code.data["language"] == "auto"
    assert :ok = CanvasTest.undo(view, board)

    refute Enum.any?(
             Graph.nodes(:sys.get_state(view.pid).socket.assigns.graph),
             &(&1.type == "code")
           )

    assert :ok = CanvasTest.redo(view, board)

    assert Graph.node(:sys.get_state(view.pid).socket.assigns.graph, code.id).data["content"] ==
             literal

    assert %{ok: true} = selected_event(view, "save", %{})
    saved = Jason.decode!(File.read!(path))
    assert saved["version"] == 2
    assert Enum.find(saved["nodes"], &(&1["id"] == code.id))["data"]["content"] == literal
  end

  test "locked code refuses source and geometry edits without changing history or disk", %{
    view: view,
    path: path,
    source: source
  } do
    code = %{
      "id" => "locked-code",
      "type" => "code",
      "locked" => true,
      "x" => 10,
      "y" => 20,
      "width" => 320,
      "height" => 180,
      "data" => %{"content" => "keep literal\r\n", "language" => "plaintext"}
    }

    source = source |> Map.put("version", 2) |> Map.update!("nodes", &(&1 ++ [code]))
    File.write!(path, Jason.encode!(source))
    render_submit(view, "open", %{"path" => path})
    before = copy_state(view)
    bytes = File.read!(path)

    view
    |> element("##{board_id(view)}-hook")
    |> render_hook("hakushi:edit", %{
      "node" => "locked-code",
      "action" => "source",
      "content" => "must not replace",
      "box" => [90, 90, 640, 480]
    })

    %{proxy: {ref, _topic, _pid}} = view
    assert_receive {^ref, {:reply, %{"ok" => false}}}
    assert copy_state(view) == before
    assert File.read!(path) == bytes
  end

  test "v1 refuses native code creation without changing graph or history", %{view: view} do
    board = board_id(view)
    before = copy_state(view)

    view
    |> element("##{board}-hook")
    |> render_hook("hakushi:draw", %{
      "tool" => "code:block",
      "box" => [0, 0, 400, 200],
      "style" => %{"content" => "literal", "language" => "plaintext"}
    })

    assert copy_state(view) == before
  end

  test "version-copy remains available for changed or unavailable server sources without acknowledging them",
       %{view: view, path: path, source: source} do
    original = File.read!(path)

    for status <- [:changed, :unavailable] do
      if status == :changed,
        do: File.write!(path, Jason.encode!(Map.put(source, "external", true))),
        else: File.rm!(path)

      send(view.pid, :check_file)
      render(view)
      assert :ok = CanvasTest.move(view, board_id(view), "idea", {321, 87})
      assert %{ok: false} = selected_event(view, "save", %{})
      before = copy_state(view)
      assert before.disk_status == status
      error = :sys.get_state(view.pid).socket.assigns.error
      generation = before.generation

      assert %{ok: true, token: token, bytes: bytes} =
               selected_event(view, "version-copy", %{"generation" => generation})

      assert Jason.decode!(bytes)["version"] == 2

      assert %{ok: true} =
               selected_event(view, "selected-version-copy-downloaded", %{
                 "generation" => generation,
                 "token" => token
               })

      assert copy_state(view) == before
      assert :sys.get_state(view.pid).socket.assigns.error == error
      File.write!(path, original)
      render_click(view, "reload")
    end
  end

  test "new v2 untitled documents refuse unnecessary conversion without adopting a source", %{
    view: view
  } do
    assert %{ok: true, generation: generation} =
             selected_event(view, "new", %{
               "generation" => workspace_integer(view, "data-generation")
             })

    before = copy_state(view)
    assert Document.format_version(before.document) == 2
    assert before.document.persistence == :untitled
    assert %{ok: false} = selected_event(view, "version-copy", %{"generation" => generation})
    assert copy_state(view) == before
    assert :sys.get_state(view.pid).socket.assigns.pending_save == nil
  end

  test "type changes cannot inject code into v1 or destructively convert code back to shapes", %{
    view: view,
    path: path,
    source: source
  } do
    board = board_id(view)
    before = copy_state(view)

    Phoenix.LiveView.send_update(view.pid, ElixirCanvasWeb.DrawingCanvas,
      id: board,
      hakushi_change:
        Change.update(nodes: [%{id: "idea", type: "code", data: %{"content" => "literal"}}])
    )

    render(view)
    assert copy_state(view) == before

    code = %{
      "id" => "literal",
      "type" => "code",
      "x" => 0,
      "y" => 0,
      "width" => 480,
      "height" => 240,
      "data" => %{"content" => "source"}
    }

    File.write!(
      path,
      Jason.encode!(source |> Map.put("version", 2) |> Map.update!("nodes", &(&1 ++ [code])))
    )

    render_click(view, "reload")
    board = board_id(view)
    before = copy_state(view)

    Phoenix.LiveView.send_update(view.pid, ElixirCanvasWeb.DrawingCanvas,
      id: board,
      hakushi_change:
        Change.update(
          nodes: [
            %{id: "literal", type: "shape", data: %{"kind" => "rect", "text" => "replacement"}}
          ]
        )
    )

    render(view)
    assert copy_state(view) == before
  end

  test "code duplicate quotas and mixed selection styles reject atomically", %{
    view: view,
    path: path,
    source: source
  } do
    content = String.duplicate("x", ElixirCanvas.CodeSnippet.source_limit())

    nodes =
      for index <- 1..4 do
        %{
          "id" => "code-#{index}",
          "type" => "code",
          "x" => index * 40,
          "y" => 0,
          "width" => 480,
          "height" => 240,
          "data" => %{"content" => content, "language" => "plaintext"}
        }
      end

    File.write!(
      path,
      Jason.encode!(source |> Map.put("version", 2) |> Map.update!("nodes", &(&1 ++ nodes)))
    )

    render_click(view, "reload")
    board = board_id(view)
    before = copy_state(view)
    assert {:error, _} = CanvasTest.duplicate(view, board, ["code-1"])
    assert copy_state(view) == before
    assert {:error, _} = CanvasTest.copy_paste(view, board, ["code-1"])
    assert copy_state(view) == before

    assert {:error, _} =
             CanvasTest.edit(view, board, ["idea", "code-1"], "style", %{
               "style" => %{"font" => "heading"}
             })

    assert copy_state(view) == before

    assert :ok =
             CanvasTest.edit(view, board, ["idea", "code-1"], "style", %{
               "style" => %{"stroke" => "red"}
             })

    state = copy_state(view)
    assert Graph.node(state.graph, "idea").data["stroke"] == "red"
    assert Graph.node(state.graph, "code-1").data["stroke"] == "red"
    assert :ok = CanvasTest.undo(view, board)

    assert Map.take(copy_state(view), [:graph, :document, :dirty]) ==
             Map.take(before, [:graph, :document, :dirty])

    assert :ok = CanvasTest.move(view, board, "code-1", {81, 32})
  end

  test "version-copy failure preserves source failure and releases only its own busy token", %{
    view: view
  } do
    generation = workspace_integer(view, "data-generation")

    render_click(view, "selected-error", %{
      "generation" => generation,
      "message" => "Permission denied."
    })

    before = copy_state(view)

    assert %{ok: true, token: token} =
             selected_event(view, "version-copy", %{"generation" => generation})

    assert %{ok: false} =
             selected_event(view, "selected-save-error", %{
               "generation" => generation - 1,
               "token" => token,
               "message" => "stale"
             })

    assert has_element?(view, "#workspace[data-file-busy=true]")

    assert %{ok: false} =
             selected_event(view, "selected-save-error", %{
               "generation" => generation,
               "token" => token,
               "message" => "Download failed."
             })

    assert has_element?(view, "#workspace[data-file-busy=false]")
    assert copy_state(view) == before
    assert :sys.get_state(view.pid).socket.assigns.error == "Permission denied. Download failed."

    assert %{ok: false} =
             selected_event(view, "selected-version-copy-downloaded", %{
               "generation" => generation,
               "token" => token
             })
  end

  test "ordinary saves persist edits without a duplicate notification", %{view: view, path: path} do
    assert :ok = CanvasTest.move(view, board_id(view), "idea", {310, 75})
    assert %{ok: true} = selected_event(view, "save", %{})

    assert {:ok, saved} = Document.open(path)
    assert Graph.node(saved.graph, "idea").x == 310
    assert Graph.node(saved.graph, "idea").y == 75
    assert has_element?(view, "#workspace[data-dirty=false]")
    assert has_element?(view, "#save-status[role=status]")
    refute has_element?(view, "#file-notice")
  end

  test "dismissing a file error preserves it through copy feedback and allows reopening",
       %{view: view, path: path} do
    original = File.read!(path)
    generation = workspace_integer(view, "data-generation")
    assert :ok = CanvasTest.move(view, board_id(view), "idea", {310, 75})
    error = "The selected file cannot be written."

    render_click(view, "selected-error", %{"generation" => generation, "message" => error})
    before_copy = copy_state(view)
    view |> element("#file-error .message-dismiss") |> render_click(%{"value" => ""})
    refute has_element?(view, "#file-error")
    assert has_element?(view, "button#save-status[aria-expanded=false]")
    assert :sys.get_state(view.pid).socket.assigns.error == error

    assert %{ok: true, token: token} =
             selected_event(view, "save-copy", %{"generation" => generation})

    assert %{ok: true} =
             selected_event(view, "selected-copy-downloaded", %{
               "generation" => generation,
               "token" => token
             })

    assert has_element?(view, "#file-notice[role=status]")
    assert has_element?(view, "button#save-status[aria-expanded=false]")
    refute has_element?(view, "#file-error")
    assert :sys.get_state(view.pid).socket.assigns.error == error
    assert copy_state(view) == before_copy
    assert File.read!(path) == original

    view |> element("button#save-status") |> render_click()
    assert has_element?(view, "#file-error[role=alert]")
    refute has_element?(view, "#save-status[role=status]")
    assert has_element?(view, "button#save-status[aria-expanded=true]")
  end

  test "notice expiry is scoped to its acknowledgement and document generation",
       %{view: view, path: path} do
    original = File.read!(path)
    generation = workspace_integer(view, "data-generation")
    before_copy = copy_state(view)

    tokens =
      for _ <- 1..2 do
        assert %{ok: true, token: token} =
                 selected_event(view, "save-copy", %{"generation" => generation})

        assert %{ok: true} =
                 selected_event(view, "selected-copy-downloaded", %{
                   "generation" => generation,
                   "token" => token
                 })

        token
      end

    [old, current] = tokens

    for {id, document_generation} <- [{old, generation}, {current, generation - 1}] do
      render_click(view, "dismiss-feedback", %{
        "kind" => "notice",
        "id" => id,
        "generation" => to_string(document_generation)
      })

      assert has_element?(view, "#file-notice")
    end

    render_click(view, "dismiss-feedback", %{
      "kind" => "notice",
      "id" => current,
      "generation" => to_string(generation)
    })

    refute has_element?(view, "#file-notice")
    assert copy_state(view) == before_copy
    assert File.read!(path) == original
  end

  test "dismissed conflicts still block writes and reopen with recovery actions",
       %{view: view, path: path, source: source} do
    assert :ok = CanvasTest.move(view, board_id(view), "idea", {310, 75})
    external = Jason.encode!(put_in(source, ["nodes", Access.at(0), "data", "text"], "External"))
    File.write!(path, external)
    send(view.pid, :check_file)
    render(view)

    view |> element("#disk-warning .message-dismiss") |> render_click(%{"value" => ""})
    refute has_element?(view, "#disk-warning")
    assert has_element?(view, "button#save-status[aria-expanded=false]")
    send(view.pid, :check_file)
    render(view)
    refute has_element?(view, "#disk-warning")

    assert %{ok: false} = selected_event(view, "save", %{})
    assert File.read!(path) == external
    assert has_element?(view, "#workspace[data-dirty=true]")

    view |> element("#save-status") |> render_click()
    assert has_element?(view, "#disk-warning [data-save-copy]")
    view |> element("#disk-warning button[phx-click=reload]") |> render_click()
    assert has_element?(view, "#workspace[data-dirty=false]")
    refute has_element?(view, "#disk-warning")
    refute has_element?(view, "button#save-status")

    assert Graph.node(:sys.get_state(view.pid).socket.assigns.graph, "idea").data["text"] ==
             "External"

    assert File.read!(path) == external
  end

  test "unsaved rename updates filename surfaces without changing graph, dirty state or history",
       %{
         view: view,
         path: path
       } do
    original = File.read!(path)
    refute has_element?(view, "#rename-document-form")

    assert %{ok: true, generation: generation} =
             selected_event(view, "new", %{
               "generation" => workspace_integer(view, "data-generation")
             })

    render_change(view, "appearance", %{"font" => "mono"})
    board = board_id(view)

    view
    |> element("##{board}-hook")
    |> render_hook("hakushi:draw", %{
      "tool" => "drawing:rect",
      "box" => [0, 0, 240, 140],
      "style" => %{"text" => "Keep history"}
    })

    %{proxy: {ref, _topic, _pid}} = view

    receive do
      {^ref, {:reply, %{"ok" => true}}} -> :ok
    after
      1_000 -> flunk("drawing did not reply")
    end

    render(view)
    before = :sys.get_state(view.pid).socket.assigns
    render_click(view, "toggle-file-menu")
    assert has_element?(view, "#rename-document-form")

    view
    |> form("#rename-document-form", %{"filename" => "  My ideas.JSON  "})
    |> render_submit()

    after_rename = :sys.get_state(view.pid).socket.assigns
    assert after_rename.document == %{before.document | filename: "My ideas.JSON"}
    assert after_rename.graph == before.graph
    assert board_id(view) == board
    assert length(CanvasTest.nodes(view, board)) == 1
    assert workspace_integer(view, "data-generation") == generation

    assert workspace_integer(view, "data-edit-version") ==
             before.edit_version

    assert has_element?(view, "#workspace[data-file-name='My ideas.JSON'][data-dirty=true]")
    assert page_title(view) == "My ideas.JSON"
    assert element(view, "#selected-file-help") |> render() =~ "My ideas.JSON"
    assert :ok = CanvasTest.undo(view, board)
    assert CanvasTest.nodes(view, board) == []
    assert :ok = CanvasTest.redo(view, board)
    assert length(CanvasTest.nodes(view, board)) == 1

    for candidate <- ["", ".json", "a/b", "a\\b", "a..b", "\nname", "name\u0085"] do
      render_submit(view, "rename_document", %{
        "filename" => candidate,
        "generation" => to_string(generation)
      })

      assert :sys.get_state(view.pid).socket.assigns.document == after_rename.document
      assert has_element?(view, "#workspace[data-dirty=true]")
    end

    render_submit(view, "rename_document", %{
      "filename" => "stale",
      "generation" => to_string(generation - 1)
    })

    assert :sys.get_state(view.pid).socket.assigns.document == after_rename.document

    assert %{ok: true, token: token, bytes: bytes, filename: "My ideas.JSON"} =
             selected_event(view, "save", %{
               "generation" => generation,
               "mode" => "save_copy",
               "filename" => "My ideas.JSON"
             })

    json = Jason.decode!(bytes)
    refute Map.has_key?(json, "title")
    refute Map.has_key?(json, "name")
    refute Map.has_key?(json, "filename")

    render_submit(view, "rename_document", %{
      "filename" => "during-save",
      "generation" => to_string(generation)
    })

    assert :sys.get_state(view.pid).socket.assigns.document == after_rename.document

    assert %{ok: true} =
             selected_event(view, "selected-copy-downloaded", %{
               "generation" => generation,
               "token" => token
             })

    render_submit(view, "rename_document", %{
      "filename" => "Second copy",
      "generation" => to_string(generation)
    })

    assert has_element?(
             view,
             "#workspace[data-file-mode=save_copy][data-file-name='Second copy.karton'][data-dirty=true]"
           )

    assert %{ok: true, filename: "Second copy.karton", bytes: ^bytes} =
             selected_event(view, "save", %{"generation" => generation, "mode" => "save_copy"})

    assert File.read!(path) == original
  end

  test "native chosen filename wins over the unsaved name and backed documents refuse rename", %{
    view: view,
    path: path
  } do
    original = File.read!(path)
    render_click(view, "toggle-file-menu")
    refute has_element?(view, "#rename-document-form")

    render_submit(view, "rename_document", %{
      "filename" => "No server rename",
      "generation" => to_string(workspace_integer(view, "data-generation"))
    })

    assert :sys.get_state(view.pid).socket.assigns.document.filename == "portable.json"

    for mode <- ["browser_file", "save_copy"] do
      assert %{ok: true, generation: generation} =
               selected_event(view, "selected-open", %{
                 "generation" => workspace_integer(view, "data-generation"),
                 "filename" => "Opened.json",
                 "bytes" => original,
                 "mode" => mode
               })

      render_click(view, "toggle-file-menu")
      refute has_element?(view, "#rename-document-form")
      before = :sys.get_state(view.pid).socket.assigns.document

      render_submit(view, "rename_document", %{
        "filename" => "No",
        "generation" => to_string(generation)
      })

      assert :sys.get_state(view.pid).socket.assigns.document == before
    end

    for chosen <- ["Chosen.json", "OS different.JSON"] do
      assert %{ok: true, generation: generation} =
               selected_event(view, "new", %{
                 "generation" => workspace_integer(view, "data-generation")
               })

      render_submit(view, "rename_document", %{
        "filename" => "Chosen",
        "generation" => to_string(generation)
      })

      assert %{ok: true, token: token} =
               selected_event(view, "save", %{
                 "generation" => generation,
                 "mode" => "browser_file",
                 "filename" => chosen
               })

      assert %{ok: true} =
               selected_event(view, "selected-saved", %{
                 "generation" => generation,
                 "token" => token
               })

      assert :sys.get_state(view.pid).socket.assigns.document.filename == chosen
      assert page_title(view) == chosen
      assert has_element?(view, ".document-name", chosen)
      render_click(view, "toggle-file-menu")
      refute has_element?(view, "#rename-document-form")
    end

    assert File.read!(path) == original
  end

  test "New replaces only a clean canvas with a fresh blank document and rejects old work", %{
    view: view,
    path: path,
    source: source
  } do
    original = File.read!(path)
    old_generation = workspace_integer(view, "data-generation")
    old_board = board_id(view)
    render_change(view, "appearance", %{"font" => "mono"})
    assert %{ok: true} = selected_event(view, "save", %{})
    previous_bytes = File.read!(path)
    previous_hash = :crypto.hash(:sha256, previous_bytes)

    assert %{ok: true, generation: generation} =
             selected_event(view, "new", %{"generation" => old_generation})

    assert generation == old_generation + 1
    refute board_id(view) == old_board
    assert CanvasTest.nodes(view, board_id(view)) == []
    assert has_element?(view, "#workspace[data-file-mode=untitled][data-dirty=false]")

    assert has_element?(
             view,
             "#workspace[data-file-name='untitled.karton'][data-drawing-font=sans]"
           )

    assert %{document: document, graph: graph, pending_save: nil} =
             :sys.get_state(view.pid).socket.assigns

    assert document == Document.new()
    assert graph == Graph.new()
    assert page_title(view) == "untitled.karton"
    assert {:error, _} = CanvasTest.undo(view, board_id(view))
    assert {:error, _} = CanvasTest.redo(view, board_id(view))
    assert CanvasTest.nodes(view, board_id(view)) == []

    send(view.pid, {:canvas_changed, old_generation, Graph.load(source)})
    render(view)

    for {event, payload} <- [
          {"new", %{"generation" => old_generation}},
          {"save", %{"generation" => old_generation}},
          {"save-copy", %{"generation" => old_generation}},
          {"selected-saved", %{"generation" => old_generation, "token" => "old-token"}},
          {"selected-copy-downloaded", %{"generation" => old_generation, "token" => "old-token"}},
          {"selected-open",
           %{
             "generation" => old_generation,
             "filename" => "old.json",
             "bytes" => original,
             "mode" => "browser_file"
           }}
        ] do
      assert %{ok: false} = selected_event(view, event, payload)
      assert workspace_integer(view, "data-generation") == generation
      assert CanvasTest.nodes(view, board_id(view)) == []
      assert has_element?(view, "#workspace[data-file-mode=untitled][data-dirty=false]")
    end

    render_click(view, "reload")
    assert CanvasTest.nodes(view, board_id(view)) == []
    assert has_element?(view, "#workspace[data-file-mode=untitled][data-dirty=false]")
    assert File.read!(path) == previous_bytes
    assert :crypto.hash(:sha256, File.read!(path)) == previous_hash
  end

  test "New refuses dirty edits and an outstanding clean save without changing generation", %{
    view: view,
    path: path
  } do
    original = File.read!(path)
    generation = workspace_integer(view, "data-generation")
    board = board_id(view)
    assert :ok = CanvasTest.edit(view, board, "idea", "text", %{"value" => "Keep my text"})
    assert %{ok: false} = selected_event(view, "new", %{"generation" => generation})
    assert workspace_integer(view, "data-generation") == generation
    assert board_id(view) == board
    assert hd(CanvasTest.nodes(view, board)).label =~ "Keep my text"
    assert has_element?(view, "#workspace[data-dirty=true]")

    render_click(view, "reload")

    assert %{ok: true, generation: selected_generation} =
             selected_event(view, "selected-open", %{
               "generation" => workspace_integer(view, "data-generation"),
               "filename" => "picked.json",
               "bytes" => original,
               "mode" => "browser_file"
             })

    selected_board = board_id(view)

    assert %{ok: true, token: token} =
             selected_event(view, "save", %{"generation" => selected_generation})

    assert %{ok: false} = selected_event(view, "new", %{"generation" => selected_generation})
    assert workspace_integer(view, "data-generation") == selected_generation
    assert board_id(view) == selected_board
    assert has_element?(view, "#workspace[data-file-mode=browser_file][data-dirty=false]")

    assert %{ok: true} =
             selected_event(view, "selected-saved", %{
               "generation" => selected_generation,
               "token" => token
             })

    assert File.read!(path) == original
  end

  test "first native save promotes only its acknowledged snapshot and preserves newer edits", %{
    view: view,
    path: path
  } do
    original = File.read!(path)

    assert %{ok: true, generation: generation} =
             selected_event(view, "new", %{
               "generation" => workspace_integer(view, "data-generation")
             })

    render_change(view, "appearance", %{"font" => "mono"})

    assert %{ok: true, token: token, bytes: bytes, saved_revision: revision} =
             selected_event(view, "save", %{
               "generation" => generation,
               "mode" => "browser_file",
               "filename" => "my-new-canvas.json"
             })

    assert has_element?(view, "#workspace[data-file-mode=untitled][data-dirty=true]")
    assert {:ok, snapshot} = Document.open_selected("my-new-canvas.json", bytes, :browser_file)
    assert snapshot.path == nil
    assert snapshot.graph == Graph.new()
    assert snapshot.source["appearance"]["font"] == "mono"
    assert revision == Base.encode16(:crypto.hash(:sha256, bytes), case: :lower)
    render_change(view, "appearance", %{"font" => "heading"})

    assert %{ok: true} =
             selected_event(view, "selected-saved", %{
               "generation" => generation,
               "token" => token
             })

    assert has_element?(view, "#workspace[data-file-mode=browser_file][data-dirty=true]")

    assert has_element?(
             view,
             "#workspace[data-file-name='my-new-canvas.json'][data-drawing-font=heading]"
           )

    assert %{ok: true, revision: ^revision, token: next_token} =
             selected_event(view, "save", %{"generation" => generation})

    assert %{ok: true} =
             selected_event(view, "selected-saved", %{
               "generation" => generation,
               "token" => next_token
             })

    assert has_element?(view, "#workspace[data-file-mode=browser_file][data-dirty=false]")
    assert File.read!(path) == original
  end

  test "failed first saves and downloaded copies never acquire a disk source", %{
    view: view,
    path: path
  } do
    original = File.read!(path)

    assert %{ok: true, generation: generation} =
             selected_event(view, "new", %{
               "generation" => workspace_integer(view, "data-generation")
             })

    render_change(view, "appearance", %{"font" => "mono"})

    assert %{ok: true, token: token} =
             selected_event(view, "save", %{
               "generation" => generation,
               "mode" => "browser_file",
               "filename" => "failed.json"
             })

    assert %{ok: false} =
             selected_event(view, "selected-save-error", %{
               "generation" => generation,
               "token" => token,
               "message" => "Write failed",
               "status" => "unavailable"
             })

    assert has_element?(
             view,
             "#workspace[data-file-mode=untitled][data-dirty=true][data-file-name='untitled.karton']"
           )

    assert :sys.get_state(view.pid).socket.assigns.disk_status == :unchanged
    refute has_element?(view, "#disk-warning")

    assert %{ok: true, token: copy_token, bytes: bytes} =
             selected_event(view, "save", %{
               "generation" => generation,
               "mode" => "save_copy",
               "filename" => "untitled.karton"
             })

    assert {:ok, copy} = Document.open_selected("untitled.karton", bytes, :save_copy)
    assert copy.source["appearance"]["font"] == "mono"

    assert %{ok: false} =
             selected_event(view, "selected-saved", %{
               "generation" => generation,
               "token" => copy_token
             })

    assert %{ok: true} =
             selected_event(view, "selected-copy-downloaded", %{
               "generation" => generation,
               "token" => copy_token
             })

    assert has_element?(view, "#workspace[data-file-mode=save_copy][data-dirty=true]")
    render_click(view, "reload")

    assert has_element?(
             view,
             "#workspace[data-file-mode=save_copy][data-dirty=true][data-drawing-font=mono]"
           )

    assert File.read!(path) == original
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

    assert has_element?(view, "#file-menu .about-section", "Karton")
    assert has_element?(view, "#file-menu .tech-stack", "Phoenix LiveView")
    assert has_element?(view, "#file-menu .tech-stack", "Hakushi")

    assert has_element?(
             view,
             "#file-menu a[href='https://github.com/rizafahmi/karton']",
             "github.com/rizafahmi/karton"
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

  test "Save a copy snapshots current typography and metadata without changing source or history",
       %{view: view, path: path, source: source} do
    source =
      source
      |> Map.put("author", %{"keep" => "top-level metadata"})
      |> Map.put("appearance", %{"font" => "sans", "future" => %{"keep" => true}})
      |> Map.put("paper", %{"background" => "dots", "grid" => 20, "annotation" => "Keep paper"})
      |> put_in(["nodes", Access.at(0), "annotation"], %{"keep" => true})
      |> put_in(["nodes", Access.at(0), "data", "font"], "handwritten")
      |> put_in(["edges", Access.at(0), "annotation"], %{"keep" => true})

    File.write!(path, Jason.encode!(source))
    render_click(view, "reload")
    original = File.read!(path)
    generation = workspace_integer(view, "data-generation")
    board = board_id(view)
    assert :ok = CanvasTest.move(view, board, "idea", {125.5, -90})
    render_change(view, "appearance", %{"font" => "heading"})
    before_copy = copy_state(view)

    assert %{
             ok: true,
             token: token,
             generation: ^generation,
             bytes: bytes,
             filename: "portable-copy.json"
           } =
             selected_event(view, "save-copy", %{"generation" => generation})

    assert {:ok, snapshot} = Document.open_selected("portable-copy.json", bytes, :save_copy)
    json = Jason.decode!(bytes)
    assert json["version"] == 1
    assert json["author"] == source["author"]
    assert json["appearance"] == %{"font" => "heading", "future" => %{"keep" => true}}
    assert json["paper"]["annotation"] == "Keep paper"
    assert hd(json["nodes"])["annotation"] == %{"keep" => true}
    assert hd(json["edges"])["annotation"] == %{"keep" => true}
    assert Graph.node(snapshot.graph, "idea").data["font"] == "handwritten"

    assert {Graph.node(snapshot.graph, "idea").x, Graph.node(snapshot.graph, "idea").y} ==
             {125.5, -90}

    assert copy_state(view) == before_copy
    assert File.read!(path) == original
    render_click(view, "toggle-file-menu")
    assert has_element?(view, "#save-document-copy[disabled][data-save-copy]")
    assert has_element?(view, "#save-file[disabled]")

    assert :ok = CanvasTest.move(view, board, "idea", {350, 70})
    render_change(view, "appearance", %{"font" => "mono"})
    newer = copy_state(view)

    assert %{ok: false} =
             selected_event(view, "selected-saved", %{
               "token" => token,
               "generation" => generation
             })

    assert copy_state(view) == newer
    assert has_element?(view, "#workspace[data-file-busy=true]")

    assert %{ok: true} =
             selected_event(view, "selected-copy-downloaded", %{
               "token" => token,
               "generation" => generation
             })

    assert copy_state(view) == newer
    assert board_id(view) == board
    assert has_element?(view, "#file-notice[role=status]")

    assert has_element?(
             view,
             "#workspace[data-file-mode=server_file][data-dirty=true][data-file-busy=false]"
           )

    refute has_element?(view, "#save-document-copy[disabled]")
    assert File.read!(path) == original

    assert :ok = CanvasTest.undo(view, board)
    assert node_box(view, board, "idea") == {125.5, -90, 240, 140}
    assert :ok = CanvasTest.undo(view, board)
    render_change(view, "appearance", %{"font" => "sans"})
    assert has_element?(view, "#workspace[data-dirty=false]")
    assert :ok = CanvasTest.redo(view, board)
    assert :ok = CanvasTest.redo(view, board)
    assert node_box(view, board, "idea") == {350, 70, 240, 140}
    assert has_element?(view, "#workspace[data-dirty=true]")
    assert File.read!(path) == original
  end

  test "clean explicit copies preserve every connected mode and implicit typography",
       %{view: view, path: path} do
    original = File.read!(path)

    for mode <- [:server_file, :browser_file, :save_copy] do
      if mode != :server_file do
        assert %{ok: true} =
                 selected_event(view, "selected-open", %{
                   "generation" => workspace_integer(view, "data-generation"),
                   "filename" => "architecture.JSON",
                   "bytes" => original,
                   "mode" => Atom.to_string(mode)
                 })
      end

      before_copy = copy_state(view)
      assert before_copy.document.persistence == mode
      refute before_copy.dirty
      generation = before_copy.generation

      assert %{ok: true, token: token, generation: ^generation, bytes: bytes, filename: filename} =
               selected_event(view, "save-copy", %{"generation" => generation})

      assert filename ==
               if(mode == :server_file, do: "portable-copy.json", else: "architecture-copy.json")

      assert bytes == Document.encode(before_copy.document, before_copy.graph)
      refute Map.has_key?(Jason.decode!(bytes), "appearance")
      assert copy_state(view) == before_copy

      assert %{ok: true} =
               selected_event(view, "selected-copy-downloaded", %{
                 "token" => token,
                 "generation" => generation
               })

      assert copy_state(view) == before_copy
      assert has_element?(view, "#workspace[data-dirty=false][data-file-busy=false]")
      assert has_element?(view, "#file-notice[role=status]")
      assert File.read!(path) == original
    end
  end

  test "explicit untitled copies never promote a source or mark clean work unsaved",
       %{view: view, path: path} do
    original = File.read!(path)

    assert %{ok: true, generation: generation} =
             selected_event(view, "new", %{
               "generation" => workspace_integer(view, "data-generation")
             })

    render_submit(view, "rename_document", %{
      "generation" => to_string(generation),
      "filename" => "My ideas.JSON"
    })

    for font <- ["sans", "mono"] do
      render_change(view, "appearance", %{"font" => font})
      before_copy = copy_state(view)
      assert before_copy.document.persistence == :untitled
      assert before_copy.document.path == nil
      assert before_copy.document.revision == nil
      assert before_copy.dirty == (font != "sans")

      assert %{ok: true, token: token, bytes: bytes, filename: "My ideas-copy.json"} =
               selected_event(view, "save-copy", %{"generation" => generation})

      json = Jason.decode!(bytes)
      assert json["nodes"] == []
      assert json["edges"] == []
      assert json["appearance"]["font"] == font

      assert %{ok: true} =
               selected_event(view, "selected-copy-downloaded", %{
                 "token" => token,
                 "generation" => generation
               })

      assert copy_state(view) == before_copy
      assert has_element?(view, "#workspace[data-file-mode=untitled][data-source-missing=true]")
      assert File.read!(path) == original
    end

    assert %{ok: true, token: token, revision: nil, bytes: bytes} =
             selected_event(view, "save", %{
               "generation" => generation,
               "mode" => "browser_file",
               "filename" => "Chosen.json"
             })

    assert Jason.decode!(bytes)["appearance"]["font"] == "mono"

    assert %{ok: true} =
             selected_event(view, "selected-saved", %{
               "token" => token,
               "generation" => generation
             })

    assert has_element?(
             view,
             "#workspace[data-file-mode=browser_file][data-file-name='Chosen.json'][data-dirty=false]"
           )

    assert File.read!(path) == original
  end

  test "a conflicted server source can be copied without overwriting external bytes or resolving its save error",
       %{view: view, path: path, source: source} do
    board = board_id(view)
    assert :ok = CanvasTest.move(view, board, "idea", {210, -40})
    render_change(view, "appearance", %{"font" => "mono"})

    external =
      Jason.encode!(put_in(source, ["nodes", Access.at(0), "data", "text"], "External editor"))

    File.write!(path, external)
    send(view.pid, :check_file)
    render(view)
    assert %{ok: false} = selected_event(view, "save", %{})
    before_copy = copy_state(view)
    original_error = :sys.get_state(view.pid).socket.assigns.error
    assert before_copy.disk_status == :changed
    assert is_binary(original_error)

    assert %{ok: true, token: token, bytes: bytes} =
             selected_event(view, "save-copy", %{"generation" => before_copy.generation})

    assert {:ok, copy} = Document.open_selected("portable-copy.json", bytes, :save_copy)
    assert Graph.node(copy.graph, "idea").x == 210
    assert Graph.node(copy.graph, "idea").data["text"] == hd(source["nodes"])["data"]["text"]
    assert Document.drawing_font(copy) == "mono"
    assert :sys.get_state(view.pid).socket.assigns.error == original_error

    assert %{ok: true} =
             selected_event(view, "selected-copy-downloaded", %{
               "token" => token,
               "generation" => before_copy.generation
             })

    assert copy_state(view) == before_copy
    assert :sys.get_state(view.pid).socket.assigns.error == original_error
    assert File.read!(path) == external
    assert has_element?(view, "#disk-warning [data-save-copy]:not([disabled])")
    refute has_element?(view, "#file-error [data-save-copy]")
    assert has_element?(view, "#file-notice[role=status]")
    assert %{ok: false} = selected_event(view, "save", %{})
    assert File.read!(path) == external
  end

  test "a missing server source is not read or recreated by an explicit copy",
       %{view: view, path: path} do
    assert :ok = CanvasTest.move(view, board_id(view), "idea", {230, -10})
    File.rm!(path)
    send(view.pid, :check_file)
    render(view)
    assert %{ok: false} = selected_event(view, "save", %{})
    before_copy = copy_state(view)
    original_error = :sys.get_state(view.pid).socket.assigns.error
    assert before_copy.disk_status == :unavailable

    assert %{ok: true, token: token, bytes: bytes} =
             selected_event(view, "save-copy", %{"generation" => before_copy.generation})

    assert {:ok, copy} = Document.open_selected("portable-copy.json", bytes, :save_copy)
    assert {Graph.node(copy.graph, "idea").x, Graph.node(copy.graph, "idea").y} == {230, -10}

    assert %{ok: true} =
             selected_event(view, "selected-copy-downloaded", %{
               "token" => token,
               "generation" => before_copy.generation
             })

    assert copy_state(view) == before_copy
    assert :sys.get_state(view.pid).socket.assigns.error == original_error
    refute File.exists?(path)
  end

  test "selected source errors survive copy failure, newer edits and successful copy acknowledgement",
       %{view: view, path: path} do
    original = File.read!(path)
    original_revision = Base.encode16(:crypto.hash(:sha256, original), case: :lower)

    for {status, message} <- [
          {"changed", "Original file changed."},
          {"unavailable", "Original file permission denied."}
        ] do
      assert %{ok: true, generation: generation} =
               selected_event(view, "selected-open", %{
                 "generation" => workspace_integer(view, "data-generation"),
                 "filename" => "architecture.json",
                 "bytes" => original,
                 "mode" => "browser_file"
               })

      board = board_id(view)
      assert :ok = CanvasTest.move(view, board, "idea", {125, -20})

      assert %{ok: true, token: save_token} =
               selected_event(view, "save", %{"generation" => generation})

      assert %{ok: false} = selected_event(view, "save-copy", %{"generation" => generation})

      assert %{ok: false} =
               selected_event(view, "selected-save-error", %{
                 "token" => save_token,
                 "generation" => generation,
                 "status" => status,
                 "message" => message
               })

      before_copy = copy_state(view)
      assert before_copy.disk_status == String.to_existing_atom(status)

      assert %{ok: true, token: copy_token, bytes: bytes} =
               selected_event(view, "save-copy", %{"generation" => generation})

      assert hd(Jason.decode!(bytes)["nodes"])["x"] == 125
      assert :sys.get_state(view.pid).socket.assigns.error == message
      assert :ok = CanvasTest.move(view, board, "idea", {350, 70})
      render_change(view, "appearance", %{"font" => "heading"})
      newer = copy_state(view)
      copy_failure = "Copy download failed."

      assert %{ok: false} =
               selected_event(view, "selected-save-error", %{
                 "token" => copy_token,
                 "generation" => generation,
                 "status" => "unavailable",
                 "message" => copy_failure
               })

      assert copy_state(view) == newer
      combined_error = :sys.get_state(view.pid).socket.assigns.error
      assert String.contains?(combined_error, message)
      assert String.contains?(combined_error, copy_failure)
      assert has_element?(view, "#workspace[data-file-busy=false][data-dirty=true]")

      assert %{ok: false} =
               selected_event(view, "selected-copy-downloaded", %{
                 "token" => copy_token,
                 "generation" => generation
               })

      assert %{ok: true, token: next_token, bytes: next_bytes} =
               selected_event(view, "save-copy", %{"generation" => generation})

      assert {:ok, next_copy} =
               Document.open_selected("architecture-copy.json", next_bytes, :save_copy)

      assert Graph.node(next_copy.graph, "idea").x == 350
      assert Document.drawing_font(next_copy) == "heading"

      assert %{ok: true} =
               selected_event(view, "selected-copy-downloaded", %{
                 "token" => next_token,
                 "generation" => generation
               })

      assert copy_state(view) == newer
      assert :sys.get_state(view.pid).socket.assigns.error == combined_error
      assert File.read!(path) == original

      assert %{ok: true, token: retry_token, revision: ^original_revision} =
               selected_event(view, "save", %{"generation" => generation})

      assert %{ok: false} =
               selected_event(view, "selected-save-error", %{
                 "token" => retry_token,
                 "generation" => generation,
                 "status" => status,
                 "message" => message
               })

      assert %{ok: true} =
               selected_event(view, "selected-reload", %{
                 "generation" => generation,
                 "edit_version" => workspace_integer(view, "data-edit-version"),
                 "filename" => "architecture.json",
                 "bytes" => original,
                 "mode" => "browser_file"
               })
    end
  end

  test "permission-only save errors offer a copy without changing selected disk status",
       %{view: view, path: path} do
    original = File.read!(path)

    assert %{ok: true, generation: generation} =
             selected_event(view, "selected-open", %{
               "generation" => workspace_integer(view, "data-generation"),
               "filename" => "architecture.json",
               "bytes" => original,
               "mode" => "browser_file"
             })

    assert :ok = CanvasTest.move(view, board_id(view), "idea", {260, 50})

    assert %{ok: true, token: save_token} =
             selected_event(view, "save", %{"generation" => generation})

    permission_error = "Write permission denied."

    assert %{ok: false} =
             selected_event(view, "selected-save-error", %{
               "token" => save_token,
               "generation" => generation,
               "message" => permission_error
             })

    before_copy = copy_state(view)
    assert before_copy.disk_status == :unchanged
    assert has_element?(view, "#file-error [data-save-copy]:not([disabled])")
    refute has_element?(view, "#disk-warning")

    render_click(view, "selected-error", %{
      "generation" => generation - 1,
      "action" => "save-copy",
      "message" => "Stale draft error."
    })

    assert :sys.get_state(view.pid).socket.assigns.error == permission_error

    render_click(view, "selected-error", %{
      "generation" => generation,
      "action" => "save-copy",
      "message" => "Thought was not added."
    })

    assert copy_state(view) == before_copy
    flush_error = :sys.get_state(view.pid).socket.assigns.error
    assert String.contains?(flush_error, permission_error)
    assert String.contains?(flush_error, "Thought was not added.")

    assert %{ok: true, token: copy_token} =
             selected_event(view, "save-copy", %{"generation" => generation})

    assert has_element?(view, "#file-error [data-save-copy][disabled]")

    assert %{ok: false} =
             selected_event(view, "selected-save-error", %{
               "token" => copy_token,
               "generation" => generation,
               "status" => "unavailable",
               "message" => "Copy download failed."
             })

    assert copy_state(view) == before_copy
    refute has_element?(view, "#disk-warning")
    combined_error = :sys.get_state(view.pid).socket.assigns.error
    assert String.contains?(combined_error, permission_error)

    assert %{ok: true, token: next_token, bytes: bytes} =
             selected_event(view, "save-copy", %{"generation" => generation})

    assert hd(Jason.decode!(bytes)["nodes"])["x"] == 260

    assert %{ok: true} =
             selected_event(view, "selected-copy-downloaded", %{
               "token" => next_token,
               "generation" => generation
             })

    assert copy_state(view) == before_copy
    assert :sys.get_state(view.pid).socket.assigns.error == combined_error
    assert has_element?(view, "#file-error [data-save-copy]:not([disabled])")
    assert File.read!(path) == original
  end

  test "an explicit copy of an edited opened copy leaves its original baseline undoable",
       %{view: view, path: path} do
    original = File.read!(path)

    assert %{ok: true, generation: generation} =
             selected_event(view, "selected-open", %{
               "generation" => workspace_integer(view, "data-generation"),
               "filename" => "architecture.json",
               "bytes" => original,
               "mode" => "save_copy"
             })

    board = board_id(view)
    assert :ok = CanvasTest.move(view, board, "idea", {280, 60})
    before_copy = copy_state(view)
    assert before_copy.dirty

    assert %{ok: true, token: token, bytes: bytes, filename: "architecture-copy.json"} =
             selected_event(view, "save-copy", %{"generation" => generation})

    assert hd(Jason.decode!(bytes)["nodes"])["x"] == 280

    assert %{ok: true} =
             selected_event(view, "selected-copy-downloaded", %{
               "token" => token,
               "generation" => generation
             })

    assert copy_state(view) == before_copy
    assert :ok = CanvasTest.undo(view, board)
    assert has_element?(view, "#workspace[data-file-mode=save_copy][data-dirty=false]")
    assert :ok = CanvasTest.redo(view, board)
    assert node_box(view, board, "idea") == {280, 60, 240, 140}
    assert File.read!(path) == original
  end

  test "explicit copies reject invalid generations, busy requests and stale acknowledgements without replacing pending work",
       %{view: view, path: path} do
    original = File.read!(path)
    before_copy = copy_state(view)
    generation = before_copy.generation

    for payload <- [
          %{},
          %{"generation" => nil},
          %{"generation" => to_string(generation)},
          %{"generation" => generation - 1},
          %{"generation" => generation + 1},
          %{"generation" => generation * 1.0}
        ] do
      assert %{ok: false} = selected_event(view, "save-copy", payload)
      assert copy_state(view) == before_copy
      assert :sys.get_state(view.pid).socket.assigns.pending_save == nil
    end

    assert %{ok: true, token: token} =
             selected_event(view, "save-copy", %{"generation" => generation})

    pending = :sys.get_state(view.pid).socket.assigns.pending_save
    assert %{ok: false} = selected_event(view, "save-copy", %{"generation" => generation})

    for event <- ["selected-copy-downloaded", "selected-save-error", "selected-saved"],
        {stale_token, stale_generation} <- [{"wrong-token", generation}, {token, generation - 1}] do
      assert %{ok: false} =
               selected_event(view, event, %{
                 "token" => stale_token,
                 "generation" => stale_generation,
                 "status" => "unavailable",
                 "message" => "Stale failure."
               })

      assert :sys.get_state(view.pid).socket.assigns.pending_save == pending
      assert :sys.get_state(view.pid).socket.assigns.error == nil
      assert copy_state(view) == before_copy
    end

    assert %{ok: false} =
             selected_event(view, "selected-save-error", %{
               "token" => token,
               "generation" => generation,
               "status" => "unavailable",
               "message" => "Copy download cancelled."
             })

    assert copy_state(view) == before_copy
    assert :sys.get_state(view.pid).socket.assigns.pending_save == nil
    assert has_element?(view, "#file-error [data-save-copy]:not([disabled])")
    assert File.read!(path) == original

    assert %{ok: true, token: next_token} =
             selected_event(view, "save-copy", %{"generation" => generation})

    refute next_token == token

    assert %{ok: false} =
             selected_event(view, "selected-copy-downloaded", %{
               "token" => token,
               "generation" => generation
             })

    assert %{ok: true} =
             selected_event(view, "selected-copy-downloaded", %{
               "token" => next_token,
               "generation" => generation
             })

    assert copy_state(view) == before_copy
    assert File.read!(path) == original
  end

  test "invalid graph snapshots do not become copies or change the source baseline",
       %{view: view, path: path} do
    original = File.read!(path)
    document = :sys.get_state(view.pid).socket.assigns.document
    node = Graph.node(document.graph, "idea")

    assert {:ok, invalid, _, _} =
             Graph.apply(
               document.graph,
               Change.update(
                 nodes: [%{id: node.id, data: Map.put(node.data, "font", "Mona Sans")}]
               )
             )

    generation = workspace_integer(view, "data-generation")
    send(view.pid, {:canvas_changed, generation, invalid})
    render(view)
    before_copy = copy_state(view)

    assert %{ok: false} = selected_event(view, "save-copy", %{"generation" => generation})
    assert copy_state(view) == before_copy
    assert before_copy.dirty
    assert :sys.get_state(view.pid).socket.assigns.pending_save == nil
    assert is_binary(:sys.get_state(view.pid).socket.assigns.error)
    assert File.read!(path) == original

    socket = %Phoenix.LiveView.Socket{assigns: %{document: nil}}

    assert {:reply, %{ok: false}, ^socket} =
             ElixirCanvasWeb.CanvasLive.handle_event(
               "save-copy",
               %{"generation" => generation},
               socket
             )
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

    send(view.pid, {:canvas_changed, workspace_integer(view, "data-generation"), graph})
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

  defp copy_state(view) do
    render(view)

    view.pid
    |> :sys.get_state()
    |> Map.fetch!(:socket)
    |> Map.fetch!(:assigns)
    |> Map.take([
      :document,
      :graph,
      :page_title,
      :path_input,
      :drawing_font,
      :dirty,
      :disk_status,
      :generation,
      :edit_version
    ])
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
