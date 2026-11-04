defmodule ElixirCanvasWeb.DrawingCode do
  @moduledoc "Literal source blocks, edited through Hakushi's ordinary atomic history path."
  use Hakushi.Kit

  alias ElixirCanvas.CodeSnippet
  alias ElixirCanvasWeb.DrawingShapes

  @style_keys ~w(fill stroke width dash radius size)
  @defaults %{
    "fill" => "none",
    "stroke" => "ink",
    "width" => 2,
    "dash" => false,
    "radius" => 0,
    "size" => "m",
    "rotation" => 0
  }

  @impl true
  def name, do: "code"
  @impl true
  def title(_messages), do: "Code"
  @impl true
  def icon, do: "type"
  @impl true
  def types, do: ["code"]
  @impl true
  def elements(_messages), do: []
  @impl true
  def tools(_messages), do: [%{tool: "block", mode: "box", label: "Code", icon: "type", key: nil}]
  @impl true
  def resizable?(_type), do: true
  @impl true
  def new_node(_item, _position, _messages), do: nil
  @impl true
  def label(_node, _messages), do: "Code block"
  @impl true
  def styles(messages), do: Enum.filter(DrawingShapes.styles(messages), &(&1.key in @style_keys))

  @impl true
  def drawn("block", %{"box" => [x, y, w, h], "style" => style}, _messages)
      when is_number(x) and is_number(y) and is_number(w) and is_number(h) and w > 0 and h > 0 and
             is_map(style) do
    with {:ok, data} <- edit("source", style, @defaults),
         {:ok, data} <- edit("style", %{"style" => Map.take(style, @style_keys)}, data) do
      %{type: "code", x: x, y: y, width: w, height: h, data: data}
    else
      _ -> nil
    end
  end

  def drawn(_tool, _params, _messages), do: nil

  @impl true
  def edit("source", %{"content" => content} = params, data) do
    candidate = Map.put(data, "content", content)

    candidate =
      if Map.has_key?(params, "language"),
        do: Map.put(candidate, "language", params["language"]),
        else: candidate

    with :ok <- CodeSnippet.validate(candidate), do: {:ok, candidate}, else: (_ -> :error)
  end

  def edit("style", %{"style" => style}, data) when is_map(style) do
    if Enum.all?(style, fn {key, value} -> valid_style?(key, value) end),
      do: {:ok, Map.merge(data, style)},
      else: :error
  end

  def edit("rotate", %{"value" => value}, data) when is_number(value),
    do: {:ok, Map.put(data, "rotation", value |> round() |> Integer.mod(360))}

  def edit(_action, _params, _data), do: :error

  defp valid_style?(key, value) when key in ["fill", "stroke"],
    do: value in ~w(none ink surface accent gray blue green yellow red violet)

  defp valid_style?("width", value), do: value in [1, 2, 4]
  defp valid_style?("dash", value), do: is_boolean(value)
  defp valid_style?("radius", value), do: value in [0, 8]
  defp valid_style?("size", value), do: value in ~w(s m l)
  defp valid_style?(_key, _value), do: false

  @impl true
  def node(assigns) do
    data = Map.merge(@defaults, assigns.node.data)
    stroke_width = if data["stroke"] == "none", do: 0, else: data["width"]

    assigns =
      assign(assigns,
        data: data,
        style: Map.take(data, @style_keys),
        w: assigns.node.width || 480,
        h: assigns.node.height || 240,
        stroke_width: stroke_width
      )

    ~H"""
    <div
      class="hakushi-shape drawing-code"
      data-kind="rect"
      data-hakushi-rotate
      data-code-node={@node.id}
      data-code-content={Jason.encode!(@data["content"])}
      data-code-language={@data["language"] || "auto"}
      data-code-size={@data["size"]}
      data-code-fill={@data["fill"]}
      data-hakushi-style={Jason.encode!(@style)}
      style={"--hakushi-rotation: #{@data["rotation"]}deg; --hakushi-shape-fill: #{fill(@data["fill"])}; --hakushi-shape-stroke: #{color(@data["stroke"])}"}
    >
      <svg
        class="hakushi-shape-outline"
        viewBox={"0 0 #{@w} #{@h}"}
        preserveAspectRatio="none"
        aria-hidden="true"
      >
        <rect
          x={@stroke_width / 2}
          y={@stroke_width / 2}
          width={max(0, @w - @stroke_width)}
          height={max(0, @h - @stroke_width)}
          rx={@data["radius"]}
          fill="var(--hakushi-shape-fill)"
          stroke="var(--hakushi-shape-stroke)"
          stroke-width={@stroke_width}
          stroke-dasharray={@data["dash"] && "8 6"}
        />
      </svg>
      <pre class="drawing-code-source"><code>{@data["content"]}</code></pre>
      <span class="drawing-code-overflow" data-code-ui role="status"></span>
      <span class="drawing-code-highlight-status" data-code-ui role="status"></span>
      <div class="drawing-code-node-actions" data-code-ui>
        <button type="button" data-code-edit>Edit source</button>
        <button type="button" data-code-copy>Copy source</button>
        <button type="button" data-code-fit>Fit to content</button>
      </div>
      <.handle side={:top} /><.handle side={:right} /><.handle side={:bottom} /><.handle side={:left} />
    </div>
    """
  end

  defp color("none"), do: "transparent"
  defp color(name), do: "var(--hakushi-shape-#{name}, var(--hakushi-text))"
  defp fill("none"), do: "transparent"

  defp fill(name),
    do:
      "color-mix(in oklab, #{color(name)} var(--hakushi-shape-tint, 16%), var(--hakushi-surface))"
end
