defmodule ElixirCanvas.CodeDocumentTest do
  use ExUnit.Case, async: true

  alias ElixirCanvas.{CodeSnippet, Document}
  alias Hakushi.{Change, Graph}

  @moduletag :tmp_dir

  test "new and created canvases explicitly use v2", %{tmp_dir: directory} do
    fresh = Document.new()
    assert Document.format_version(fresh) == 2
    assert {:ok, bytes, prepared} = Document.prepare_save(fresh, fresh.graph)
    assert Jason.decode!(bytes)["version"] == 2
    assert Document.format_version(prepared) == 2

    assert {:ok, created} = Document.create(Path.join(directory, "new.json"))
    assert Document.format_version(created) == 2
    assert Jason.decode!(File.read!(created.path))["version"] == 2
  end

  test "v2 round trips literal source, authored order, large integers and unknown metadata" do
    literal = "\uFEFF\tdef hello, do: \"😀é\"\r\n" <> String.duplicate(" ", 2_001) <> "\rnext\n\t"
    source = source([code("z-first", literal), code("a-second", "")])
    assert {:ok, document} = selected(source)
    assert Graph.node(document.graph, "z-first").data["content"] == literal
    assert {:ok, bytes, saved} = Document.prepare_save(document, document.graph)
    encoded = Jason.decode!(bytes)
    assert Enum.map(encoded["nodes"], & &1["id"]) == ["z-first", "a-second"]
    assert hd(encoded["nodes"])["data"] == hd(source["nodes"])["data"]
    assert hd(encoded["nodes"])["future-node"] == hd(source["nodes"])["future-node"]
    assert encoded["paper"] == source["paper"]
    assert encoded["appearance"] == source["appearance"]
    assert encoded["future-root"] == source["future-root"]
    assert {:ok, reopened} = Document.open_selected("saved.json", bytes, :save_copy)
    assert reopened.graph == saved.graph

    assert {:ok, moved, _, _} =
             Graph.apply(document.graph, Change.move([%{id: "z-first", x: -12.5, y: 16}]))

    assert {:ok, moved_bytes, _} = Document.prepare_save(document, moved)
    moved_source = Jason.decode!(moved_bytes)
    assert hd(moved_source["nodes"])["data"]["content"] == literal
    assert hd(moved_source["nodes"])["x"] == -12.5
  end

  test "deleting every code node retains v2 rather than downgrading" do
    assert {:ok, document} = selected(source([code("code", "hello")]))
    assert {:ok, empty, _, _} = Graph.apply(document.graph, Change.delete(nodes: ["code"]))
    assert {:ok, bytes, prepared} = Document.prepare_save(document, empty)
    assert Jason.decode!(bytes)["nodes"] == []
    assert Document.format_version(prepared) == 2
    assert {:error, _} = Document.prepare_version_copy(prepared, empty)
  end

  test "v1 sources stay v1 and reject code without an upgrade" do
    legacy = source([]) |> Map.put("version", 1)
    assert {:ok, document} = selected(legacy)
    assert Document.format_version(document) == 1
    assert document.source == legacy
    assert {:ok, bytes, saved} = Document.prepare_save(document, document.graph)
    assert Jason.decode!(bytes)["version"] == 1
    assert Document.format_version(saved) == 1
    illegal = Map.put(legacy, "nodes", [code("code", "hello")])
    assert {:error, _} = Document.decode(Jason.encode!(illegal))
    assert {:error, _} = Document.prepare_save(document, Graph.load(illegal))
    assert document.source == legacy
  end

  test "external files require a version while internal missing-version source defaults to v1" do
    assert {:error, _} = selected(Map.delete(source([]), "version"))
    assert Document.format_version(%Document{source: %{}}) == 1
  end

  test "explicit version copy changes only the captured root version and never adopts state" do
    legacy_nodes =
      for id <- ["z-first", "a-second"] do
        code(id, "")
        |> Map.put("type", "shape")
        |> update_in(["data"], &Map.merge(&1, %{"kind" => "rect", "text" => id}))
      end

    legacy =
      source(legacy_nodes)
      |> Map.put("version", 1)
      |> Map.put("edges", [
        %{
          "id" => "loop",
          "source" => "z-first",
          "target" => "z-first",
          "data" => %{"future" => 9_007_199_254_740_993},
          "future-edge" => [nil, true]
        }
      ])

    assert {:ok, document} = selected(legacy)
    assert document.revision == :crypto.hash(:sha256, Jason.encode!(legacy))

    assert {:ok, captured, _, _} =
             Graph.apply(document.graph, Change.move([%{id: "z-first", x: 71, y: -13}]))

    assert {:ok, baseline, _} = Document.prepare_save(document, captured)
    assert {:ok, copy} = Document.prepare_version_copy(document, captured)
    assert Jason.decode!(copy) == Map.put(Jason.decode!(baseline), "version", 2)
    assert document.source == legacy
    assert Document.format_version(document) == 1
    assert {:ok, reopened} = Document.open_selected("copy-v2.json", copy, :save_copy)
    assert Document.format_version(reopened) == 2
    assert reopened.graph == captured
    refute document.graph == captured
  end

  test "code source and aggregate limits apply both when decoding and preparing saves" do
    limit = String.duplicate("é", div(CodeSnippet.source_limit(), 2))
    nodes = for id <- 1..4, do: code("code-#{id}", limit)
    assert {:ok, document} = selected(source(nodes))
    assert {:ok, _bytes, _} = Document.prepare_save(document, document.graph)

    for invalid <- [source(nodes ++ [code("extra", "x")]), source([code("large", limit <> "x")])] do
      assert {:error, _} = Document.decode(Jason.encode!(invalid))
      assert {:error, _} = Document.prepare_save(Document.new(), Graph.load(invalid))
    end

    binary = source([code("binary", <<255>>)])
    assert {:error, reason} = Document.prepare_save(Document.new(), Graph.load(binary))
    assert reason =~ "UTF-8"
  end

  test "attachment and code budgets are independent, and code never carries attachments" do
    content = String.duplicate("x", CodeSnippet.source_limit())
    codes = for id <- 1..4, do: code("code-#{id}", content)

    shapes =
      for id <- 1..4 do
        code("shape-#{id}", "")
        |> Map.put("type", "shape")
        |> Map.put("data", %{
          "kind" => "rect",
          "text" => "caption",
          "attachment" => %{
            "filename" => "notes.txt",
            "media_type" => "text/plain",
            "encoding" => "utf-8",
            "content" => content
          }
        })
      end

    assert {:ok, document} = selected(source(codes ++ shapes))
    assert {:ok, _bytes, _} = Document.prepare_save(document, document.graph)
    invalid = put_in(code("invalid", ""), ["data", "attachment"], nil)
    assert {:error, _} = selected(source([invalid]))
  end

  test "code enforces existing geometry and style sets, not ordinary caption limits" do
    base = code("code", String.duplicate("x", 2_001))
    assert {:ok, _} = selected(source([base]))

    for invalid <- [
          Map.put(base, "width", 0),
          Map.put(base, "parent", "group"),
          put_in(base, ["data", "size"], "xl"),
          put_in(base, ["data", "rotation"], "0"),
          put_in(base, ["data", "language"], ""),
          put_in(base, ["data", "content"], nil)
        ] do
      assert {:error, _} = selected(source([invalid]))
    end
  end

  test "candidate graph validation enforces retained version, style and literal source without encoding" do
    graph = Graph.load(source([code("code", "literal\r\n\t")]))
    assert :ok = Document.validate_graph(Document.new(), graph)
    legacy = %Document{source: %{"version" => 1}}
    assert {:error, _} = Document.validate_graph(legacy, graph)

    for data <- [
          %{"content" => <<255>>},
          %{"content" => "valid", "size" => "xl"},
          %{"content" => String.duplicate("x", CodeSnippet.source_limit() + 1)}
        ] do
      invalid = code("invalid", "") |> Map.put("data", data)

      assert {:error, _} =
               Document.validate_graph(Document.new(), Graph.load(source([invalid])))
    end
  end

  defp selected(source),
    do: Document.open_selected("code.json", Jason.encode!(source), :save_copy)

  defp source(nodes) do
    %{
      "version" => 2,
      "nodes" => nodes,
      "edges" => [],
      "paper" => %{"background" => "dots", "grid" => 20, "future-paper" => [nil, 7]},
      "appearance" => %{"font" => "handwritten", "future-appearance" => %{"keep" => true}},
      "future-root" => %{"integer" => 9_007_199_254_740_993, "unknown" => [nil, false, "kept"]}
    }
  end

  defp code(id, content) do
    %{
      "id" => id,
      "type" => "code",
      "x" => 9_007_199_254_740_993,
      "y" => -20,
      "width" => 480,
      "height" => 240,
      "locked" => false,
      "future-node" => %{"integer" => 9_007_199_254_740_995},
      "data" => %{
        "content" => content,
        "language" => "future-language",
        "size" => "m",
        "future-data" => %{"nested" => [nil, 9_007_199_254_740_997]}
      }
    }
  end
end
