defmodule ElixirCanvasWeb.DrawingCodeTest do
  use ExUnit.Case, async: true

  alias ElixirCanvas.CodeSnippet
  alias ElixirCanvasWeb.DrawingCode

  test "drawing consumes final source and geometry without text-caption truncation" do
    source = "\uFEFF\t" <> String.duplicate("code\r\n", 600) <> "\r  \n"

    node =
      DrawingCode.drawn(
        "block",
        %{"box" => [11, 22, 640, 320], "style" => %{"content" => source, "language" => "elixir"}},
        %{}
      )

    assert node.type == "code"
    assert {node.x, node.y, node.width, node.height} == {11, 22, 640, 320}
    assert node.data["content"] == source
    refute Map.has_key?(node.data, "text")
  end

  test "source updates preserve unknown metadata and reject oversized input without truncating" do
    data = %{
      "content" => "old",
      "language" => "rust",
      "custom" => %{"bytes" => "keep"},
      "size" => "l"
    }

    source = String.duplicate("x", CodeSnippet.source_limit())
    assert {:ok, edited} = DrawingCode.edit("source", %{"content" => source}, data)
    assert edited["content"] == source
    assert edited["custom"] == data["custom"]
    assert edited["size"] == "l"
    assert edited["language"] == "rust"
    assert :error = DrawingCode.edit("source", %{"content" => source <> "x"}, data)
    assert :error = DrawingCode.edit("text", %{"value" => "wrong path"}, data)
  end

  test "only code-eligible styles are exposed and unsupported commands are refused atomically" do
    data = %{"content" => "source", "custom" => 17}

    assert {:ok, updated} =
             DrawingCode.edit("style", %{"style" => %{"fill" => "accent", "size" => "s"}}, data)

    assert updated == Map.merge(data, %{"fill" => "accent", "size" => "s"})

    for key <- ~w(font align arrow),
        do:
          assert(
            :error ==
              DrawingCode.edit(
                "style",
                %{"style" => %{"stroke" => "red", key => "unsupported"}},
                data
              )
          )

    assert {:ok, rotated} = DrawingCode.edit("rotate", %{"value" => -90}, data)
    assert rotated["rotation"] == 270
  end
end
