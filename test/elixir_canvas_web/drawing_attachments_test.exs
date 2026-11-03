defmodule ElixirCanvasWeb.DrawingAttachmentsTest do
  use ExUnit.Case, async: true

  alias ElixirCanvas.Attachment
  alias ElixirCanvasWeb.{DrawingCanvas, DrawingShapes}
  alias Hakushi.Graph

  test "missing or cleared attachment captions use the original filename as their accessible fallback" do
    attachment = attachment("Source body")
    node = Graph.node(graph(attachment), "notes")

    for data <- [Map.delete(node.data, "text"), Map.put(node.data, "text", "")] do
      assert DrawingShapes.label(%{node | data: data}, %{}) =~ attachment["filename"]
    end

    assert DrawingShapes.label(node, %{}) =~ "Caption"
  end

  test "attachment creation refuses invalid metadata and geometry instead of silently truncating content" do
    for attachment <- [
          nil,
          %{},
          Map.put(attachment(""), "content", "\0"),
          Map.put(attachment(""), "content", String.duplicate("x", Attachment.file_limit() + 1))
        ] do
      assert nil ==
               DrawingShapes.drawn(
                 "attachment",
                 %{"box" => [0, 0, 240, 112], "attachment" => attachment},
                 %{}
               )
    end

    for box <- [nil, [], [0, 0], [0, 0, 0, 112], [0, 0, 240, -1], ["0", 0, 240, 112]] do
      assert nil ==
               DrawingShapes.drawn(
                 "attachment",
                 %{"box" => box, "attachment" => attachment("")},
                 %{}
               )
    end
  end

  test "on-demand reads refuse invalid stored attachment content without changing the socket" do
    invalid = socket(graph(Map.put(attachment(""), "content", "\0")), true)

    assert {:reply, %{"ok" => false, "error" => reason}, ^invalid} =
             DrawingCanvas.handle_event(
               "drawing:attachment-read",
               %{"generation" => 7, "node" => "notes"},
               invalid
             )

    assert reason =~ "binary control"
  end

  defp attachment(content) do
    %{
      "filename" => "notes.md",
      "media_type" => "text/markdown",
      "encoding" => "utf-8",
      "content" => content,
      "future" => %{"reviewed" => true}
    }
  end

  defp graph(attachment) do
    Graph.new(
      nodes: [
        %{
          id: "notes",
          type: "shape",
          x: 0,
          y: 0,
          width: 240,
          height: 112,
          data: %{"kind" => "rect", "text" => "Caption", "attachment" => attachment}
        },
        %{
          id: "ordinary",
          type: "shape",
          x: 320,
          y: 0,
          width: 240,
          height: 112,
          data: %{"kind" => "rect", "text" => "No attachment"}
        }
      ]
    )
  end

  defp socket(graph, readonly) do
    %Phoenix.LiveView.Socket{
      assigns: %{
        __changed__: %{},
        graph: graph,
        generation: 7,
        readonly: readonly,
        undo: [:existing_undo],
        redo: [:existing_redo],
        dirty: false,
        edit_version: 3
      }
    }
  end
end
