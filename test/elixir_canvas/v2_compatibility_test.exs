defmodule ElixirCanvas.V2CompatibilityTest do
  use ExUnit.Case, async: true

  alias ElixirCanvas.Document
  alias Hakushi.{Change, Graph}

  @moduletag :tmp_dir

  test "v2 literal code and extensions survive an unrelated shape edit", %{tmp_dir: directory} do
    fixture = Path.expand("../../shared/fixtures/v2/code-compatibility.json", __DIR__)
    original = File.read!(fixture)
    assert {:ok, graph, source} = Document.decode(original)
    assert {:ok, document} = Document.open(fixture)
    assert document.graph == graph
    assert document.source == source
    assert Document.format_version(document) == 2

    explicit = "\uFEFFdef greet(name):\r\n\treturn \"こんにちは 😀 \" + name\r# café\n"
    automatic = "first\nsecond\r\nthird\r\t末尾"
    assert Graph.node(graph, "code-explicit").data["content"] == explicit
    assert Graph.node(graph, "code-explicit").data["language"] == "python"
    assert Graph.node(graph, "code-auto").data["content"] == automatic
    refute Map.has_key?(Graph.node(graph, "code-auto").data, "language")
    assert Graph.node(graph, "code-future").data["language"] == "future-language"
    assert Graph.node(graph, "code-future").data["content"] == "λ = 42\n"
    assert Graph.edge(graph, "link").target == "shape"

    assert {:ok, moved, _, _} =
             Graph.apply(graph, Change.move([%{id: "shape", x: -42.5, y: 130}]))

    assert {:ok, bytes, prepared} = Document.prepare_save(document, moved)
    assert {:ok, decoded_graph, saved} = Document.decode(bytes)
    assert decoded_graph == moved
    assert saved == prepared.source
    assert saved["version"] == 2
    assert saved["future"] == source["future"]
    assert saved["appearance"] == source["appearance"]
    assert saved["paper"]["future"] == source["paper"]["future"]

    for id <- ["code-explicit", "code-auto", "code-future"] do
      before = Enum.find(source["nodes"], &(&1["id"] == id))
      after_save = Enum.find(saved["nodes"], &(&1["id"] == id))
      assert after_save["data"] == before["data"]
      assert Map.take(after_save, ~w(x y width height)) == Map.take(before, ~w(x y width height))
      assert after_save["future-node"] == before["future-node"]
    end

    shape = Enum.find(saved["nodes"], &(&1["id"] == "shape"))
    assert shape["x"] == -42.5
    assert shape["y"] == 130
    assert shape["future-node"] == "shape metadata"
    assert hd(saved["edges"])["future-edge"] == ["kept", true]
    assert hd(saved["edges"])["data"]["future"] == %{"weight" => 3}

    path = Path.join(directory, "saved.json")
    File.write!(path, bytes)
    assert {:ok, reopened} = Document.open(path)
    assert reopened.graph == moved
    assert reopened.source == saved
    assert Graph.node(reopened.graph, "code-explicit").data["content"] == explicit
    assert Graph.node(reopened.graph, "code-auto").data["content"] == automatic
    refute Map.has_key?(Graph.node(reopened.graph, "code-auto").data, "language")
    assert Graph.edge(reopened.graph, "link").source == "code-explicit"
    assert File.read!(fixture) == original
  end
end
