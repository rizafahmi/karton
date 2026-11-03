defmodule ElixirCanvasWeb.AttachmentLiveTest do
  use ElixirCanvasWeb.ConnCase, async: true

  import Phoenix.LiveViewTest

  alias ElixirCanvas.{Attachment, Document}
  alias ElixirCanvasWeb.DrawingCanvas
  alias Hakushi.{Change, Graph, Node}
  alias Hakushi.Test, as: CanvasTest

  @moduletag :tmp_dir

  setup %{conn: conn, tmp_dir: directory} do
    path = Path.join(directory, "attachments.json")
    assert {:ok, _document} = Document.create(path)
    {:ok, view, _html} = live(conn, ~p"/")
    render_submit(view, "open", %{"path" => path})
    %{view: view, path: path}
  end

  test "public attachment draw, read, undo, redo, save-copy and reopen retain exact bytes and native history",
       %{view: view, path: path, tmp_dir: directory} do
    original_bytes = File.read!(path)
    board = board_id(view)
    generation = workspace_integer(view, "data-generation")

    content =
      "\uFEFF# Literal <script>not executable</script>\r\n" <>
        String.duplicate("日本語 👩🏽‍💻 e\u0301 **markdown source**\t\r\n", 160) <>
        "attachment-content-never-rendered-7cf3"

    assert String.length(content) > 2_000
    attachment = attachment("研究.md", content, "text/markdown")

    assert %{"ok" => true, "drawn" => id} = import_attachment(view, board, generation, attachment)
    [drawn] = CanvasTest.nodes(view, board)
    assert drawn.id == id
    assert {drawn.width, drawn.height} == {240, 112}

    assert has_element?(
             view,
             ".hakushi-node[data-id=\"#{id}\"] .drawing-typography[data-attachment=\"text/markdown\"]"
           )

    refute render(view) =~ content
    refute render(view) =~ "attachment-content-never-rendered-7cf3"
    assert has_element?(view, "#workspace[data-dirty=true]")
    assert length(history(view, board).undo) == 1

    before_read = state(view)
    before_history = history(view, board)

    for _read <- 1..2 do
      assert %{"ok" => true, "attachment" => ^attachment} =
               read_attachment(view, board, generation, id)

      assert state(view) == before_read
      assert history(view, board) == before_history
    end

    assert :ok = CanvasTest.undo(view, board)
    assert CanvasTest.nodes(view, board) == []
    assert has_element?(view, "#workspace[data-dirty=false]")
    assert history(view, board).undo == []
    assert length(history(view, board).redo) == 1
    refused_state = state(view)
    refused_history = history(view, board)

    assert %{"ok" => false, "error" => _reason} = read_attachment(view, board, generation, id)
    assert %{"ok" => false, "error" => _reason} = read_attachment(view, board, generation - 1, id)

    assert %{"ok" => false, "error" => _reason} =
             import_attachment(view, board, generation - 1, attachment)

    assert state(view) == refused_state
    assert history(view, board) == refused_history

    assert :ok = CanvasTest.redo(view, board)
    assert [^drawn] = CanvasTest.nodes(view, board)

    assert %{"ok" => true, "attachment" => ^attachment} =
             read_attachment(view, board, generation, id)

    before_copy = state(view)
    copy_history = history(view, board)
    assert %{ok: false} = selected_event(view, "save-copy", %{"generation" => generation - 1})
    assert state(view) == before_copy
    assert history(view, board) == copy_history

    assert %{ok: true, token: token, bytes: bytes, filename: filename} =
             selected_event(view, "save-copy", %{"generation" => generation})

    copy_path = Path.join(directory, filename)
    File.write!(copy_path, bytes)
    assert {:ok, copied} = Document.open(copy_path)
    assert Graph.node(copied.graph, id).data["attachment"] == attachment
    assert copied.source["nodes"] |> hd() |> get_in(["data", "attachment", "content"]) == content

    assert %{ok: true} =
             selected_event(view, "selected-copy-downloaded", %{
               "generation" => generation,
               "token" => token
             })

    assert state(view) == before_copy
    assert history(view, board) == copy_history
    assert File.read!(path) == original_bytes

    assert :ok = CanvasTest.undo(view, board)
    assert CanvasTest.nodes(view, board) == []
    assert has_element?(view, "#workspace[data-dirty=false]")
    assert :ok = CanvasTest.redo(view, board)
    assert [^drawn] = CanvasTest.nodes(view, board)
    before_save_history = history(view, board)
    assert %{ok: true} = selected_event(view, "save", %{"generation" => generation})
    assert history(view, board) == before_save_history
    assert has_element?(view, "#workspace[data-dirty=false]")
    assert {:ok, saved} = Document.open(path)
    assert Graph.node(saved.graph, id).data["attachment"] == attachment
    assert File.read!(path) == bytes
    clean = state(view)

    assert %{"ok" => true, "attachment" => ^attachment} =
             read_attachment(view, board, generation, id)

    assert state(view) == clean
    assert history(view, board) == before_save_history

    render_click(view, "reload")
    current_board = board_id(view)
    current_generation = workspace_integer(view, "data-generation")
    assert current_generation == generation + 1
    assert history(view, current_board) == %{undo: [], redo: []}
    reopened_state = state(view)

    assert %{"ok" => false, "error" => _reason} =
             read_attachment(view, current_board, generation, id)

    assert %{"ok" => false, "error" => _reason} =
             import_attachment(view, current_board, generation, attachment)

    assert state(view) == reopened_state
    assert history(view, current_board) == %{undo: [], redo: []}

    assert %{"ok" => true, "attachment" => ^attachment} =
             read_attachment(view, current_board, current_generation, id)

    assert state(view) == reopened_state
  end

  test "native move, caption, style, duplicate, paste and remove keep attachment metadata undoable",
       %{view: view, path: path, tmp_dir: directory} do
    board = board_id(view)
    generation = workspace_integer(view, "data-generation")

    attachment =
      attachment("notes.txt", String.duplicate("Exact Unicode Ω\r\n", 200), "text/plain")

    assert %{"ok" => true, "drawn" => id} = import_attachment(view, board, generation, attachment)
    assert :ok = CanvasTest.move(view, board, id, {-125.5, 80.25})
    assert :ok = CanvasTest.edit(view, board, id, "text", %{"value" => "My caption"})

    assert :ok =
             CanvasTest.edit(view, board, id, "style", %{
               "style" => %{
                 "font" => "mono",
                 "stroke" => "accent",
                 "fill" => "surface",
                 "radius" => 8
               }
             })

    styled = Graph.node(state(view).graph, id)
    assert styled.data["attachment"] == attachment
    assert styled.data["text"] == "My caption"
    assert styled.data["font"] == "mono"
    assert {styled.x, styled.y} == {-125.5, 80.25}
    assert :ok = CanvasTest.undo(view, board)
    assert Graph.node(state(view).graph, id).data["attachment"] == attachment
    assert :ok = CanvasTest.redo(view, board)
    assert Graph.node(state(view).graph, id) == styled

    assert {:ok, [duplicate]} = CanvasTest.duplicate(view, board, [id])
    assert Graph.node(state(view).graph, duplicate).data == styled.data

    assert %{"ok" => true, "attachment" => ^attachment} =
             read_attachment(view, board, generation, duplicate)

    assert :ok = CanvasTest.undo(view, board)
    refute Graph.node(state(view).graph, duplicate)
    assert :ok = CanvasTest.redo(view, board)
    assert Graph.node(state(view).graph, duplicate).data == styled.data
    assert :ok = CanvasTest.connect(view, board, {id, "right"}, {duplicate, "left"})
    [connector] = CanvasTest.edges(view, board)

    assert {connector.source, connector.source_handle, connector.target, connector.target_handle} ==
             {id, "right", duplicate, "left"}

    assert :ok = CanvasTest.undo(view, board)
    assert CanvasTest.edges(view, board) == []
    assert :ok = CanvasTest.redo(view, board)
    assert [^connector] = CanvasTest.edges(view, board)

    assert {:ok, [pasted]} = CanvasTest.copy_paste(view, board, [duplicate], {520, -40})
    assert Graph.node(state(view).graph, pasted).data == styled.data
    assert :ok = CanvasTest.remove(view, board, nodes: [id])
    refute Graph.node(state(view).graph, id)
    assert :ok = CanvasTest.undo(view, board)
    assert Graph.node(state(view).graph, id) == styled
    assert :ok = CanvasTest.redo(view, board)
    refute Graph.node(state(view).graph, id)

    graph = state(view).graph
    expected = Graph.nodes(graph)
    for node <- expected, do: assert(node.data["attachment"] == attachment)
    before_copy = state(view)
    before_history = history(view, board)

    assert %{ok: true, token: token, bytes: bytes} =
             selected_event(view, "save-copy", %{"generation" => generation})

    copy_path = Path.join(directory, "edited-copy.json")
    File.write!(copy_path, bytes)
    assert {:ok, reopened} = Document.open(copy_path)
    assert Graph.nodes(reopened.graph) == expected

    assert %{ok: true} =
             selected_event(view, "selected-copy-downloaded", %{
               "generation" => generation,
               "token" => token
             })

    assert state(view) == before_copy
    assert history(view, board) == before_history
    assert %{ok: true} = selected_event(view, "save", %{"generation" => generation})
    assert File.read!(path) == bytes
    assert {:ok, saved} = Document.open(path)
    assert Graph.nodes(saved.graph) == expected
  end

  test "aggregate import, duplicate and paste refusal preserve clean graph and pending redo at the exact limit",
       %{view: view, path: path} do
    full = attachment("full.txt", String.duplicate("x", Attachment.file_limit()), "text/plain")
    nodes = for id <- 1..4, do: node("full-#{id}", full)
    source = Graph.new(nodes: nodes) |> Graph.dump() |> Map.put("version", 1)
    File.write!(path, Jason.encode!(source))
    render_click(view, "reload")
    board = board_id(view)
    generation = workspace_integer(view, "data-generation")
    original = File.read!(path)
    assert :ok = CanvasTest.move(view, board, "full-1", {40, 50})
    assert :ok = CanvasTest.undo(view, board)
    assert has_element?(view, "#workspace[data-dirty=false]")
    before = state(view)
    before_history = history(view, board)
    assert length(before_history.redo) == 1

    assert {:error, reason} = CanvasTest.duplicate(view, board, ["full-1"])
    assert reason =~ "1 MiB"
    assert state(view) == before
    assert history(view, board) == before_history
    assert {:error, reason} = CanvasTest.copy_paste(view, board, ["full-1"])
    assert reason =~ "1 MiB"
    assert state(view) == before
    assert history(view, board) == before_history

    assert %{"ok" => false, "error" => reason} =
             import_attachment(
               view,
               board,
               generation,
               attachment("extra.txt", "x", "text/plain")
             )

    assert reason =~ "1 MiB"
    assert state(view) == before
    assert history(view, board) == before_history
    assert File.read!(path) == original

    assert :ok = CanvasTest.redo(view, board)

    assert {Graph.node(state(view).graph, "full-1").x, Graph.node(state(view).graph, "full-1").y} ==
             {40, 50}

    assert %{"ok" => true, "drawn" => empty} =
             import_attachment(view, board, generation, attachment("empty.txt", "", "text/plain"))

    assert :ok = Attachment.validate_graph(state(view).graph)

    assert %{"ok" => true, "attachment" => %{"content" => ""}} =
             read_attachment(view, board, generation, empty)

    assert :ok = CanvasTest.undo(view, board)
    refute Graph.node(state(view).graph, empty)
    assert :ok = CanvasTest.remove(view, board, nodes: ["full-4"])
    assert {:ok, [duplicate]} = CanvasTest.duplicate(view, board, ["full-1"])
    assert Graph.node(state(view).graph, duplicate).data["attachment"] == full
    assert :ok = Attachment.validate_graph(state(view).graph)
    assert length(Graph.nodes(state(view).graph)) == 4
  end

  test "invalid public imports and reads retain empty graph, dirty state, and native history",
       %{view: view, path: path} do
    board = board_id(view)
    generation = workspace_integer(view, "data-generation")
    valid = attachment("notes.txt", "Valid text", "text/plain")
    before = state(view)
    before_history = history(view, board)
    original = File.read!(path)

    for invalid <- [
          nil,
          %{},
          Map.put(valid, "filename", "../outside.txt"),
          Map.put(valid, "media_type", "text/html"),
          Map.put(valid, "encoding", "base64"),
          Map.put(valid, "content", "binary\0text"),
          Map.put(valid, "content", String.duplicate("é", Attachment.file_limit()))
        ] do
      assert %{"ok" => false, "error" => reason} =
               import_attachment(view, board, generation, invalid)

      assert is_binary(reason) and reason != ""
      assert state(view) == before
      assert history(view, board) == before_history
    end

    payload = %{
      "tool" => "drawing:attachment",
      "generation" => generation,
      "box" => [0, 0, 240, 112],
      "attachment" => valid
    }

    for invalid <- [
          Map.delete(payload, "generation"),
          Map.put(payload, "generation", to_string(generation)),
          Map.put(payload, "parent", "missing"),
          Map.put(payload, "box", [0, 0, 0, 112])
        ] do
      assert %{"ok" => false, "error" => _reason} =
               canvas_event(view, board, "hakushi:draw", invalid)

      assert state(view) == before
      assert history(view, board) == before_history
    end

    for payload <- [
          %{},
          %{"generation" => generation, "node" => "missing"},
          %{"generation" => generation, "node" => nil}
        ] do
      assert %{"ok" => false, "error" => _reason} =
               canvas_event(view, board, "drawing:attachment-read", payload)

      assert state(view) == before
      assert history(view, board) == before_history
    end

    assert File.read!(path) == original
  end

  test "programmatic native add and metadata updates are atomically quota-checked before changing clean state",
       %{view: view, path: path} do
    full = attachment("full.txt", String.duplicate("x", Attachment.file_limit()), "text/plain")
    empty = attachment("empty.txt", "", "text/plain")
    nodes = for(id <- 1..4, do: node("full-#{id}", full)) ++ [node("empty", empty)]
    source = Graph.new(nodes: nodes) |> Graph.dump() |> Map.put("version", 1)
    File.write!(path, Jason.encode!(source))
    render_click(view, "reload")
    board = board_id(view)
    assert :ok = CanvasTest.move(view, board, "full-1", {40, 50})
    assert :ok = CanvasTest.undo(view, board)
    before = state(view)
    before_history = history(view, board)
    original = File.read!(path)
    empty_node = Graph.node(before.graph, "empty")

    commands = [
      Change.add([node("extra", attachment("extra.txt", "x", "text/plain"))]),
      Change.update(
        nodes: [
          %{
            id: "empty",
            data:
              Map.put(empty_node.data, "attachment", attachment("empty.txt", "x", "text/plain"))
          }
        ]
      ),
      Change.update(
        nodes: [
          %{
            id: "empty",
            data: Map.put(empty_node.data, "attachment", Map.put(empty, "content", "\0"))
          }
        ]
      ),
      Change.update(nodes: [%{id: "empty", type: "shape-line"}])
    ]

    for command <- commands do
      Phoenix.LiveView.send_update(view.pid, DrawingCanvas, id: board, hakushi_change: command)
      assert state(view) == before
      assert history(view, board) == before_history
      assert is_binary(CanvasTest.notice(view, board))
      assert File.read!(path) == original
    end

    assert :ok = CanvasTest.redo(view, board)
    assert Graph.node(state(view).graph, "full-1").x == 40
    assert Graph.node(state(view).graph, "empty").data["attachment"] == empty
  end

  test "readonly canvas imports refuse while public attachment reads keep clean state and pending redo",
       %{view: view, path: path} do
    board = board_id(view)
    generation = workspace_integer(view, "data-generation")
    attachment = attachment("read-only.md", "\uFEFF# Read only\r\n", "text/markdown")
    assert %{"ok" => true, "drawn" => id} = import_attachment(view, board, generation, attachment)
    assert %{ok: true} = selected_event(view, "save", %{"generation" => generation})
    original = File.read!(path)
    assert :ok = CanvasTest.move(view, board, id, {300, 200})
    assert :ok = CanvasTest.undo(view, board)
    assert has_element?(view, "#workspace[data-dirty=false]")

    Phoenix.LiveView.send_update(view.pid, DrawingCanvas,
      id: board,
      graph: state(view).graph,
      readonly: true
    )

    before = state(view)
    before_history = history(view, board)
    assert length(before_history.redo) == 1

    assert %{"ok" => false, "error" => reason} =
             import_attachment(view, board, generation, attachment)

    assert reason =~ "read-only"
    assert state(view) == before
    assert history(view, board) == before_history

    assert %{"ok" => true, "attachment" => ^attachment} =
             read_attachment(view, board, generation, id)

    assert state(view) == before
    assert history(view, board) == before_history
    assert File.read!(path) == original
  end

  defp import_attachment(view, board, generation, attachment) do
    canvas_event(view, board, "hakushi:draw", %{
      "tool" => "drawing:attachment",
      "generation" => generation,
      "box" => [-12.5, 45.5, 240, 112],
      "attachment" => attachment
    })
  end

  defp read_attachment(view, board, generation, id),
    do:
      canvas_event(view, board, "drawing:attachment-read", %{
        "generation" => generation,
        "node" => id
      })

  defp canvas_event(view, board, event, payload) do
    render(view)
    view |> element("##{board}-hook") |> render_hook(event, payload)
    reply(view, event)
  end

  defp selected_event(view, event, payload) do
    render(view)
    view |> element("#workspace") |> render_hook(event, payload)
    reply(view, event)
  end

  defp reply(view, event) do
    %{proxy: {ref, _topic, _pid}} = view

    receive do
      {^ref, {:reply, reply}} -> reply
    after
      1_000 -> flunk("attachment event #{event} did not reply")
    end
  end

  defp state(view) do
    render(view)

    view.pid
    |> :sys.get_state()
    |> Map.fetch!(:socket)
    |> Map.fetch!(:assigns)
    |> Map.take([
      :document,
      :graph,
      :dirty,
      :disk_status,
      :generation,
      :edit_version,
      :drawing_font
    ])
  end

  defp history(view, board) do
    render(view)
    {components, _ids, _counter} = :sys.get_state(view.pid).components

    Enum.find_value(components, fn
      {_cid, {DrawingCanvas, ^board, assigns, _private, _fingerprints}} ->
        Map.take(assigns, [:undo, :redo])

      _component ->
        nil
    end)
  end

  defp board_id(view) do
    view
    |> render()
    |> LazyHTML.from_fragment()
    |> LazyHTML.query(".drawing-board")
    |> LazyHTML.attribute("id")
    |> List.first()
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

  defp attachment(filename, content, media_type) do
    %{
      "filename" => filename,
      "media_type" => media_type,
      "encoding" => "utf-8",
      "content" => content,
      "future" => %{"reviewed" => true, "author" => "未来", "values" => [nil, "Ω"]}
    }
  end

  defp node(id, attachment) do
    Node.new(%{
      id: id,
      type: "shape",
      x: 0,
      y: 0,
      width: 240,
      height: 112,
      data: %{"kind" => "rect", "text" => "Caption", "attachment" => attachment}
    })
  end
end
