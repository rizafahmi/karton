defmodule ElixirCanvas.V1CompatibilityTest do
  use ExUnit.Case, async: true

  alias ElixirCanvas.Document
  alias Hakushi.{Change, Graph}

  @fixture Path.expand("../../shared/fixtures/v1/compatibility.json", __DIR__)
  @moduletag :tmp_dir

  test "v1 graph and authored metadata survive a round trip and an unrelated move", %{
    tmp_dir: dir
  } do
    original = File.read!(@fixture)
    assert {:ok, graph, source} = Document.decode(original)
    assert {:ok, document} = Document.open(@fixture)
    assert document.graph == graph
    assert document.source == source
    assert Document.format_version(document) == 1

    attachment = Graph.node(graph, "rect").data["attachment"]
    assert attachment["content"] == "\uFEFF雪\r\nCafé\t🌿\r\n"
    assert attachment["filename"] == "資料.md"
    empty_attachment = Graph.node(graph, "ellipse").data["attachment"]
    assert empty_attachment["content"] == ""
    assert empty_attachment["media_type"] == "text/plain"
    assert Graph.node(graph, "ellipse").data["font"] == "handwritten"
    assert Graph.node(graph, "ellipse").data["size"] == "l"
    assert Graph.node(graph, "ellipse").data["align"] == "right"
    assert Graph.node(graph, "rect").locked
    assert Graph.node(graph, "line").data["from"] == [12, 58]
    assert Graph.edge(graph, "loop").source == "diamond"
    assert Graph.edge(graph, "loop").target == "diamond"
    assert Graph.edge(graph, "step-solid").path == "step"
    assert Graph.edge(graph, "step-solid").marker == "none"
    assert Graph.edge(graph, "step-solid").animated == true
    assert Graph.edge(graph, "step-solid").source_handle == nil
    assert Graph.edge(graph, "step-solid").target_handle == nil
    assert Graph.edge(graph, "straight-collision").path == "straight"
    assert Graph.edge(graph, "straight-collision").source_handle == "bottom"
    assert Graph.edge(graph, "straight-collision").target_handle == "top"
    assert {:ok, unchanged_bytes, unchanged} = Document.prepare_save(document, graph)
    assert {:ok, unchanged_graph, unchanged_source} = Document.decode(unchanged_bytes)
    assert unchanged_graph == graph
    assert unchanged_source == unchanged.source

    assert {:ok, moved, _, _} =
             Graph.apply(graph, Change.move([%{id: "text", x: -75.5, y: 420.25}]))

    assert Graph.node(moved, "text") == %{Graph.node(graph, "text") | x: -75.5, y: 420.25}
    assert {:ok, bytes, prepared} = Document.prepare_save(document, moved)
    path = Path.join(dir, "saved.json")
    File.write!(path, bytes)
    assert {:ok, reopened} = Document.open(path)
    assert reopened.graph == moved
    assert reopened.source == prepared.source
    assert reopened.source["version"] == 1
    assert reopened.source["future"] == source["future"]
    assert reopened.source["appearance"] == source["appearance"]
    assert reopened.source["paper"]["future"] == source["paper"]["future"]

    for id <- ~w(rect ellipse diamond triangle line) do
      assert Graph.node(reopened.graph, id) == Graph.node(graph, id)
    end

    for id <- ~w(styled loop step-solid straight-collision) do
      assert Graph.edge(reopened.graph, id) == Graph.edge(graph, id)
    end

    assert Graph.node(reopened.graph, "rect").data["attachment"] == attachment
    assert Graph.node(reopened.graph, "ellipse").data["attachment"] == empty_attachment
    assert object(reopened.source["nodes"], "rect")["future"] == %{"owner" => "α"}
    assert object(reopened.source["nodes"], "rect")["data"]["future"] == [1, "keep"]
    assert object(reopened.source["nodes"], "line")["data"]["future"] == "line"
    assert object(reopened.source["edges"], "styled")["future"] == "edge"

    assert object(reopened.source["edges"], "styled")["data"]["connector_style"] == %{
             "stroke" => "red",
             "width" => 4,
             "dash" => true,
             "future" => "kept"
           }

    assert object(reopened.source["edges"], "styled")["data"]["future"] == %{
             "weight" => 9_007_199_254_740_993
           }

    assert object(reopened.source["edges"], "step-solid")["data"]["connector_style"] == %{
             "stroke" => "green",
             "width" => 1,
             "dash" => false,
             "unsupported" => 99
           }

    assert object(reopened.source["edges"], "straight-collision")["data"] == %{
             "connector_style" => "legacy-collision",
             "future" => "collision-kept"
           }

    assert reopened.source["future"]["sequence"] == 9_007_199_254_740_993
    assert File.read!(@fixture) == original
  end

  test "explicit v1-to-v2 version copy preserves graph and metadata without upgrading original",
       %{
         tmp_dir: dir
       } do
    original = File.read!(@fixture)
    path = Path.join(dir, "v1-source.json")
    File.write!(path, original)
    assert {:ok, document} = Document.open(path)
    assert Document.format_version(document) == 1

    assert {:ok, v2_bytes} = Document.prepare_version_copy(document, document.graph)
    assert Document.format_version(document) == 1
    assert File.read!(path) == original

    v2_path = Path.join(dir, "converted-v2.json")
    File.write!(v2_path, v2_bytes)
    assert {:ok, converted} = Document.open(v2_path)
    assert Document.format_version(converted) == 2
    assert converted.graph == document.graph

    assert Map.delete(converted.source, "version") ==
             Map.delete(
               Jason.decode!(elem(Document.prepare_save(document, document.graph), 1)),
               "version"
             )

    assert {:error, _} = Document.prepare_version_copy(converted, converted.graph)
    assert File.read!(@fixture) == original
  end

  defp object(objects, id), do: Enum.find(objects, &(&1["id"] == id))
end
