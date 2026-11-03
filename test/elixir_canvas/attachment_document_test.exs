defmodule ElixirCanvas.AttachmentDocumentTest do
  use ExUnit.Case, async: true

  alias ElixirCanvas.{Attachment, Document}
  alias ElixirCanvasWeb.DrawingShapes
  alias Hakushi.{Change, Graph}

  @moduletag :tmp_dir

  test "real saved bytes and reopening preserve long Unicode Markdown, CRLF, BOM, empty files and future metadata",
       %{tmp_dir: directory} do
    content =
      "\uFEFF# Literal <script>never executed</script>\r\n" <>
        String.duplicate("日本語 👩🏽‍💻 e\u0301 **source**\t\r\n", 180) <>
        "last line has no newline"

    assert String.length(content) > 2_000
    attachment = attachment("研究.md", content, "text/markdown")
    empty = attachment("empty.txt", "", "text/plain")

    original =
      source([node("notes", attachment), node("empty", empty)])
      |> Map.put("future", %{"author" => "Future me", "revision" => 17})
      |> Map.put("paper", %{"background" => "none", "grid" => 20, "future" => ["keep"]})
      |> put_in(["nodes", Access.at(0), "annotation"], %{"reviewed" => true})

    path = Path.join(directory, "attachments.json")
    File.write!(path, Jason.encode!(original))
    assert {:ok, document} = Document.open(path)
    initial_bytes = File.read!(path)
    notes = Graph.node(document.graph, "notes")

    assert notes.data["attachment"] == attachment
    assert Graph.node(document.graph, "empty").data["attachment"] == empty

    assert {:ok, moved, _, undo_move} =
             Graph.apply(
               document.graph,
               Change.move([%{id: "notes", x: -125.5, y: 80.25, width: 310, height: 145}])
             )

    assert {:ok, styled_data} =
             DrawingShapes.edit(
               "style",
               %{"style" => %{"stroke" => "accent", "fill" => "surface", "font" => "mono"}},
               notes.data
             )

    assert {:ok, styled, _, undo_style} =
             Graph.apply(moved, Change.update(nodes: [%{id: "notes", data: styled_data}]))

    assert_payloads(styled, %{"notes" => attachment, "empty" => empty})
    assert Graph.node(styled, "notes").data["future"] == notes.data["future"]
    assert {:ok, unstyled, _, redo_style} = Graph.apply(styled, undo_style)
    assert unstyled == moved
    assert {:ok, unmoved, _, redo_move} = Graph.apply(unstyled, undo_move)
    assert unmoved == document.graph
    assert {:ok, moved_again, _, _} = Graph.apply(unmoved, redo_move)
    assert {:ok, styled_again, _, _} = Graph.apply(moved_again, redo_style)
    assert styled_again == styled

    duplicate = %{Graph.node(styled_again, "notes") | id: "duplicate", x: 24, y: 24}
    assert {:ok, duplicated, _, undo_add} = Graph.apply(styled_again, Change.add([duplicate]))

    assert_payloads(duplicated, %{
      "notes" => attachment,
      "empty" => empty,
      "duplicate" => attachment
    })

    assert Graph.node(duplicated, "duplicate").data == styled_data
    assert {:ok, without_copy, _, redo_add} = Graph.apply(duplicated, undo_add)
    assert without_copy == styled_again
    assert {:ok, duplicated_again, _, _} = Graph.apply(without_copy, redo_add)
    assert duplicated_again == duplicated

    assert {:ok, removed, _, undo_remove} =
             Graph.apply(duplicated_again, Change.delete(nodes: ["empty"]))

    refute Graph.node(removed, "empty")
    assert {:ok, restored, _, redo_remove} = Graph.apply(removed, undo_remove)

    assert_payloads(restored, %{
      "notes" => attachment,
      "empty" => empty,
      "duplicate" => attachment
    })

    assert {:ok, removed_again, _, _} = Graph.apply(restored, redo_remove)
    assert_payloads(removed_again, %{"notes" => attachment, "duplicate" => attachment})
    assert :ok = Attachment.validate_graph(removed_again)
    assert File.read!(path) == initial_bytes

    expected_bytes = Document.encode(document, removed_again)
    assert {:ok, saved} = Document.save(document, removed_again)
    assert File.read!(path) == expected_bytes
    assert {:ok, reopened} = Document.open(path)
    assert reopened.graph == removed_again
    assert reopened.revision == :crypto.hash(:sha256, expected_bytes)
    assert reopened.source["future"] == original["future"]
    assert reopened.source["paper"]["future"] == original["paper"]["future"]

    persisted = Jason.decode!(File.read!(path))
    [persisted_notes, persisted_duplicate] = persisted["nodes"]
    assert persisted_notes["annotation"] == %{"reviewed" => true}
    assert persisted_notes["data"]["attachment"] == attachment
    assert persisted_duplicate["data"]["attachment"] == attachment
    assert persisted_notes["data"]["attachment"]["content"] == content
    assert persisted_notes["data"]["text"] == "Editable caption"
    assert byte_size(persisted_notes["data"]["attachment"]["content"]) == byte_size(content)

    assert {:ok, resaved} = Document.save(saved, removed_again)
    assert File.read!(path) == expected_bytes
    assert resaved.revision == saved.revision
    assert {:ok, selected} = Document.open_selected("copy.json", expected_bytes, :save_copy)
    assert selected.graph == reopened.graph
    assert selected.source == persisted
  end

  test "empty attachment content is present, saved and reopened without being treated as missing",
       %{tmp_dir: directory} do
    attachment = attachment("empty.md", "", "text/markdown")
    path = Path.join(directory, "empty.json")
    assert {:ok, document} = Document.create(path)

    created =
      DrawingShapes.drawn(
        "attachment",
        %{"box" => [12, 24, 240, 112], "attachment" => attachment},
        %{}
      )

    assert {:ok, graph, _, inverse} =
             Graph.apply(document.graph, Change.add([Map.put(created, :id, "empty")]))

    assert {:ok, _saved} = Document.save(document, graph)
    assert {:ok, reopened} = Document.open(path)
    assert Graph.node(reopened.graph, "empty").data["attachment"] == attachment

    assert Jason.decode!(File.read!(path))["nodes"]
           |> hd()
           |> get_in(["data", "attachment", "content"]) == ""

    assert {:ok, removed, _, _} = Graph.apply(reopened.graph, inverse)
    assert removed == Graph.new()
  end

  test "invalid attachment metadata and binary text refuse decode and saves without changing real bytes",
       %{tmp_dir: directory} do
    path = Path.join(directory, "unchanged.json")
    assert {:ok, document} = Document.create(path)
    original = File.read!(path)
    invalid_path = Path.join(directory, "invalid-incoming.json")
    valid = attachment("notes.txt", "Valid text", "text/plain")

    invalid = [
      nil,
      %{},
      Map.delete(valid, "content"),
      Map.put(valid, "filename", "../outside.txt"),
      Map.put(valid, "filename", String.duplicate("é", 128)),
      Map.put(valid, "media_type", "text/html"),
      Map.put(valid, "encoding", "base64"),
      Map.put(valid, "content", "hello\0world"),
      Map.put(valid, "content", "hello\u0085world"),
      Map.put(valid, "content", 1),
      Map.put(valid, "content", String.duplicate("x", Attachment.file_limit() + 1))
    ]

    for attachment <- invalid do
      source = source([node("bad", attachment)])
      bytes = Jason.encode!(source)
      graph = Graph.load(source)
      assert {:error, _reason} = Document.decode(bytes)
      assert {:error, _reason} = Document.open_selected("invalid.json", bytes, :save_copy)
      File.write!(invalid_path, bytes)
      assert {:error, _reason} = Document.open(invalid_path)
      assert File.read!(invalid_path) == bytes
      assert {:error, _reason} = Document.prepare_save(document, graph)
      assert {:error, _reason} = Document.save(document, graph)
      assert File.read!(path) == original
    end

    binary = Map.put(valid, "content", <<0xFF, 0xFE>>)
    graph = Graph.load(source([node("binary", binary)]))
    assert {:error, reason} = Document.prepare_save(document, graph)
    assert reason =~ "UTF-8"
    assert {:error, _reason} = Document.save(document, graph)
    assert File.read!(path) == original

    encoded = Jason.encode!(source([node("binary", Map.put(valid, "content", "replace-me"))]))
    malformed = :binary.replace(encoded, "replace-me", <<0xFF, 0xFE>>)
    assert {:error, _reason} = Document.decode(malformed)
    assert {:error, _reason} = Document.open_selected("binary.json", malformed, :browser_file)
    File.write!(invalid_path, malformed)
    assert {:error, _reason} = Document.open(invalid_path)
    assert File.read!(invalid_path) == malformed
  end

  test "aggregate byte limits include duplicates when opening or preparing a file",
       %{tmp_dir: directory} do
    path = Path.join(directory, "limits.json")
    assert {:ok, document} = Document.create(path)
    original = File.read!(path)

    attachment =
      attachment("full.txt", String.duplicate("x", Attachment.file_limit()), "text/plain")

    nodes = for id <- 1..4, do: node("file-#{id}", attachment)
    bytes = Jason.encode!(source(nodes))

    assert {:ok, at_limit, _source} = Document.decode(bytes)
    assert {:ok, _bytes, _prepared} = Document.prepare_save(document, at_limit)

    for extra <- [
          node("one-byte", attachment("extra.txt", "x", "text/plain")),
          node("duplicate", attachment)
        ] do
      source = source(nodes ++ [extra])
      assert {:error, reason} = Document.decode(Jason.encode!(source))
      assert reason =~ "1 MiB"
      assert {:error, ^reason} = Document.prepare_save(document, Graph.load(source))
      assert {:error, ^reason} = Document.save(document, Graph.load(source))
      assert File.read!(path) == original
    end
  end

  test "attachment content does not relax ordinary caption limits or permit attachments on lines" do
    attachment = attachment("long.txt", String.duplicate("x", 3_001), "text/plain")
    ordinary = node("notes", attachment)
    assert {:ok, _graph, _source} = Document.decode(Jason.encode!(source([ordinary])))

    oversized_caption = put_in(ordinary, ["data", "text"], String.duplicate("x", 2_001))
    assert {:error, reason} = Document.decode(Jason.encode!(source([oversized_caption])))
    assert reason =~ "2000 characters"

    line = %{
      "id" => "line",
      "type" => "shape-line",
      "x" => 0,
      "y" => 0,
      "width" => 120,
      "height" => 40,
      "data" => %{"from" => [12, 12], "to" => [108, 28], "attachment" => attachment}
    }

    assert {:error, reason} = Document.decode(Jason.encode!(source([line])))
    assert reason =~ "shape nodes"
  end

  defp assert_payloads(graph, expected) do
    for {id, attachment} <- expected do
      assert Graph.node(graph, id).data["attachment"] == attachment
    end
  end

  defp attachment(filename, content, media_type) do
    %{
      "filename" => filename,
      "media_type" => media_type,
      "encoding" => "utf-8",
      "content" => content,
      "future" => %{"author" => "未来", "values" => [true, nil, "α"]}
    }
  end

  defp node(id, attachment) do
    %{
      "id" => id,
      "type" => "shape",
      "x" => 10,
      "y" => 20,
      "width" => 240,
      "height" => 112,
      "data" => %{
        "kind" => "rect",
        "text" => "Editable caption",
        "fill" => "none",
        "stroke" => "ink",
        "future" => %{"keep" => ["authored", 7]},
        "attachment" => attachment
      }
    }
  end

  defp source(nodes), do: %{"version" => 1, "nodes" => nodes, "edges" => []}
end
