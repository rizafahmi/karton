defmodule ElixirCanvas.CodeSnippetTest do
  use ExUnit.Case, async: true

  alias ElixirCanvas.CodeSnippet
  alias Hakushi.Graph

  test "literal source accepts empty text, BOM, tabs, mixed endings and unknown language metadata" do
    for content <- ["", "\uFEFF\tα\r\nβ\rγ\n  \t", String.duplicate("x", 2_001)] do
      data = %{"content" => content, "language" => "future-language", "future" => [nil, 9]}
      assert :ok = CodeSnippet.validate(data)
      assert :ok = CodeSnippet.validate(Map.delete(data, "language"))
      assert :ok = CodeSnippet.validate(Map.put(data, "language", "auto"))
    end
  end

  test "source byte limit is inclusive and counts UTF-8 bytes rather than characters" do
    content = String.duplicate("é", div(CodeSnippet.source_limit(), 2))
    assert byte_size(content) == 262_144
    assert :ok = CodeSnippet.validate(%{"content" => content})
    assert {:error, _} = CodeSnippet.validate(%{"content" => content <> "x"})
  end

  test "invalid source and language are rejected without accepting binary controls" do
    for content <- [nil, 1, [], <<255>>, <<192, 175>>] do
      assert {:error, _} = CodeSnippet.validate(%{"content" => content})
    end

    for control <-
          Enum.to_list(0..8) ++ [11, 12] ++ Enum.to_list(14..31) ++ Enum.to_list(127..159) do
      assert {:error, _} =
               CodeSnippet.validate(%{"content" => "before" <> <<control::utf8>> <> "after"})
    end

    for language <- [nil, "", false, 1, <<255>>] do
      assert {:error, _} = CodeSnippet.validate(%{"content" => "", "language" => language})
    end

    assert {:error, _} = CodeSnippet.validate(%{})
    assert {:error, _} = CodeSnippet.validate(nil)
    assert {:error, _} = CodeSnippet.validate(%{"content" => "", "attachment" => nil})
    assert {:error, _} = CodeSnippet.validate(%{"content" => "", :attachment => %{}})
  end

  test "aggregate quota counts every copy in lists and graph maps and ignores ordinary captions" do
    content = String.duplicate("x", CodeSnippet.source_limit())
    nodes = for id <- 1..4, do: node("code-#{id}", content)
    assert CodeSnippet.total_limit() == 4 * byte_size(content)
    assert :ok = CodeSnippet.validate_graph(nodes)
    assert :ok = CodeSnippet.validate_graph(Graph.load(%{"nodes" => nodes, "edges" => []}))

    extra = node("extra", "x")
    assert {:error, _} = CodeSnippet.validate_graph(nodes ++ [extra])
    assert {:error, _} = CodeSnippet.validate_graph(Graph.load(%{"nodes" => nodes ++ [extra]}))

    assert :ok =
             CodeSnippet.validate_graph(
               nodes ++ [%{"type" => "shape", "data" => %{"content" => content}}]
             )

    assert {:error, _} = CodeSnippet.validate_graph(nil)
  end

  defp node(id, content) do
    %{
      "id" => id,
      "type" => "code",
      "x" => 0,
      "y" => 0,
      "width" => 400,
      "height" => 240,
      "data" => %{"content" => content}
    }
  end
end
