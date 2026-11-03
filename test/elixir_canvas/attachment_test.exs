defmodule ElixirCanvas.AttachmentTest do
  use ExUnit.Case, async: true

  alias ElixirCanvas.Attachment
  alias Hakushi.Graph

  test "filenames are safe basenames with a UTF-8 byte limit, not a character limit" do
    for filename <- [
          "notes.txt",
          "日本語.md",
          "résumé.txt",
          ".notes",
          "a..b.txt",
          " authored.txt ",
          String.duplicate("a", 255),
          String.duplicate("é", 127) <> "a"
        ] do
      assert :ok = Attachment.validate(Map.put(attachment(""), "filename", filename))
    end

    for filename <- [
          nil,
          12,
          [],
          %{},
          "",
          " \t ",
          ".",
          "..",
          "../notes.txt",
          "a/b.txt",
          "a\\b.txt",
          "a\0b.txt",
          "notes\n.txt",
          "notes\r.txt",
          "notes\t.txt",
          "notes\u007F.txt",
          "notes\u0085.txt",
          "notes\u009F.txt",
          <<255>>,
          String.duplicate("a", 256),
          String.duplicate("é", 128)
        ] do
      assert {:error, reason} = Attachment.validate(Map.put(attachment(""), "filename", filename))
      assert reason =~ "filename"
    end
  end

  test "the text media types and encoding are required and exact" do
    for field <- ~w(filename media_type encoding content) do
      assert {:error, _reason} = Attachment.validate(Map.delete(attachment(""), field))
    end

    for media_type <- [
          nil,
          "",
          "text/html",
          "application/json",
          "text/plain;charset=utf-8",
          "Text/Plain",
          "application/octet-stream",
          12,
          [],
          %{}
        ] do
      assert {:error, reason} =
               Attachment.validate(Map.put(attachment(""), "media_type", media_type))

      assert reason =~ "media type"
    end

    for encoding <- [nil, "", "UTF-8", "utf8", "base64", "utf-16", 12, [], %{}] do
      assert {:error, reason} =
               Attachment.validate(Map.put(attachment(""), "encoding", encoding))

      assert reason =~ "encoding"
    end

    for invalid <- [nil, "", [], 1, true] do
      assert {:error, _reason} = Attachment.validate(invalid)
    end
  end

  test "content rejects malformed UTF-8 and every binary control except tab LF and CR" do
    assert :ok = Attachment.validate(attachment("\t\r\n"))

    controls = Enum.to_list(0..8) ++ [11, 12] ++ Enum.to_list(14..31) ++ Enum.to_list(127..159)

    for control <- controls do
      assert {:error, reason} =
               Attachment.validate(attachment("before" <> <<control::utf8>> <> "after"))

      assert reason =~ "binary control"
    end

    for content <- [
          nil,
          [],
          %{},
          1,
          true,
          <<255>>,
          <<0xC3>>,
          <<0xC0, 0xAF>>,
          <<0xED, 0xA0, 0x80>>
        ] do
      assert {:error, _reason} = Attachment.validate(attachment(content))
    end
  end

  test "individual content size is measured in bytes with an inclusive 256 KiB boundary" do
    ascii = String.duplicate("x", Attachment.file_limit())
    unicode = String.duplicate("é", div(Attachment.file_limit(), 2))

    assert :ok = Attachment.validate(attachment(ascii))
    assert :ok = Attachment.validate(attachment(unicode))

    for content <- [ascii <> "x", unicode <> "x", String.duplicate("é", Attachment.file_limit())] do
      assert {:error, reason} = Attachment.validate(attachment(content))
      assert reason =~ "256 KiB"
    end
  end

  test "graph and JSON node list totals include identical duplicated content" do
    content = String.duplicate("é", div(Attachment.file_limit(), 2))
    nodes = for id <- 1..4, do: node("attachment-#{id}", attachment(content))
    graph = Graph.new(nodes: nodes)

    assert :ok = Attachment.validate_graph(graph)
    assert :ok = Attachment.validate_graph(Graph.dump(graph)["nodes"])
    assert :ok = Attachment.validate_graph(nodes ++ [node("empty", attachment(""))])
    assert :ok = Attachment.validate_graph(Graph.new())
    assert :ok = Attachment.validate_graph([])

    for nodes <- [
          nodes ++ [node("one-byte", attachment("x"))],
          nodes ++ [node("duplicate", attachment(content))]
        ] do
      assert {:error, reason} = Attachment.validate_graph(nodes)
      assert reason =~ "1 MiB"
      assert {:error, ^reason} = Attachment.validate_graph(Graph.new(nodes: nodes))
    end
  end

  test "aggregate validation checks each attachment while leaving ordinary future metadata alone" do
    ordinary = %{
      id: "ordinary",
      type: "shape",
      data: %{"kind" => "rect", "future" => %{"attachment" => "not reserved"}}
    }

    assert :ok = Attachment.validate_graph([ordinary, node("valid", attachment(""))])

    for invalid <- [
          nil,
          %{},
          attachment(<<255>>),
          attachment("\0"),
          attachment(String.duplicate("x", Attachment.file_limit() + 1))
        ] do
      assert {:error, _reason} = Attachment.validate_graph([ordinary, node("bad", invalid)])

      assert {:error, _reason} =
               Attachment.validate_graph(Graph.new(nodes: [node("bad", invalid)]))
    end

    assert {:error, reason} =
             Attachment.validate_graph([%{node("line", attachment("")) | type: "shape-line"}])

    assert reason =~ "shape nodes"
    assert {:error, _reason} = Attachment.validate_graph(%{})
  end

  defp attachment(content) do
    %{
      "filename" => "notes.md",
      "media_type" => "text/markdown",
      "encoding" => "utf-8",
      "content" => content
    }
  end

  defp node(id, attachment) do
    %{
      id: id,
      type: "shape",
      x: 0,
      y: 0,
      width: 240,
      height: 112,
      data: %{"kind" => "rect", "text" => "Editable caption", "attachment" => attachment}
    }
  end
end
