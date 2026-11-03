defmodule ElixirCanvasWeb.DrawingTypography do
  @moduledoc false
  use Phoenix.Component

  alias Hakushi.Kits.Shapes

  def node(%{node: %{type: "shape-line"}} = assigns), do: Shapes.node(assigns)

  def node(assigns) do
    attachment = Hakushi.Kit.get(assigns.node.data, "attachment")

    assigns =
      assign(assigns,
        font: Hakushi.Kit.get(assigns.node.data, "font"),
        attachment_type: if(is_map(attachment), do: attachment["media_type"])
      )

    ~H"""
    <div
      class="drawing-typography"
      data-drawing-font={@font}
      data-attachment={@attachment_type}
      title={@attachment_type && "Embedded text copy. Double-click or press Enter/F2 to preview."}
    >
      <Shapes.node
        node={@node}
        canvas={@canvas}
        readonly={@readonly}
        target={@target}
        messages={@messages}
      />
    </div>
    """
  end
end
