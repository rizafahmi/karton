defmodule ElixirCanvasWeb.DrawingCanvas do
  @moduledoc """
  Local drawing canvas adapter. Hakushi owns ordinary edits and their history;
  order entries share that same history because Hakushi has no reorder change.
  """
  use ElixirCanvasWeb, :live_component

  alias Hakushi.{Canvas, Graph}

  @impl true
  defdelegate mount(socket), to: Canvas

  @impl true
  def update(assigns, socket) do
    # These are the existing workspace's resolved canvas options, not a second
    # general-purpose canvas API. Keep kit rendering and all events in Hakushi.
    defaults = %{
      new_node: nil,
      join: nil,
      user: nil,
      grid: 20,
      snap: false,
      wheel: :pan,
      refit: false,
      min_zoom: 0.1,
      max_zoom: 4.0,
      layout: {:layered, :right},
      tidy: false,
      controls: true,
      readonly: false,
      arrange: false,
      follow: true,
      show_people: true,
      node_label: &Canvas.label/1,
      locale: Application.get_env(:hakushi, :locale, "en"),
      overrides: nil,
      rest: %{},
      node_slots: [],
      person_slot: [],
      empty_slot: []
    }

    Canvas.update(Map.merge(defaults, assigns), socket)
  end

  @impl true
  defdelegate render(assigns), to: Canvas

  @impl true
  def handle_event("drawing:stack", %{"direction" => direction, "nodes" => ids}, socket)
      when direction in ["front", "back"] and is_list(ids) do
    graph = socket.assigns.graph
    selected = MapSet.new(ids)

    {chosen, other} =
      Enum.split_with(graph.node_order, fn id ->
        node = Graph.node(graph, id)

        MapSet.member?(selected, id) and node.type in ElixirCanvasWeb.DrawingShapes.types() and
          not node.locked
      end)

    order = if direction == "front", do: other ++ chosen, else: chosen ++ other

    if socket.assigns.readonly or order == graph.node_order do
      {:reply, %{"ok" => true}, socket}
    else
      inverse = {:drawing_order, graph.node_order, chosen}
      socket = put_order(socket, order)
      socket = assign(socket, undo: Enum.take([inverse | socket.assigns.undo], 100), redo: [])
      {:reply, %{"ok" => true, "select" => ids}, socket}
    end
  end

  def handle_event("drawing:stack", _params, socket),
    do: {:reply, %{"error" => "Invalid stacking command."}, socket}

  def handle_event("hakushi:undo" = event, params, socket),
    do: step_order(socket, :undo, :redo, event, params)

  def handle_event("hakushi:redo" = event, params, socket),
    do: step_order(socket, :redo, :undo, event, params)

  def handle_event(event, params, socket), do: Canvas.handle_event(event, params, socket)

  defp step_order(socket, from, to, event, params) do
    case Map.fetch!(socket.assigns, from) do
      [{:drawing_order, order, selected} | rest] when not socket.assigns.readonly ->
        inverse = {:drawing_order, socket.assigns.graph.node_order, selected}
        socket = put_order(socket, order)

        socket =
          socket |> assign(from, rest) |> assign(to, [inverse | Map.fetch!(socket.assigns, to)])

        {:reply, %{"ok" => true, "select" => selected}, socket}

      _ ->
        Canvas.handle_event(event, params, socket)
    end
  end

  defp put_order(socket, order) do
    graph = %{socket.assigns.graph | node_order: order}
    send(self(), {:canvas_changed, graph})

    socket
    |> assign(:graph, graph)
    |> stream(:nodes, Graph.nodes(graph), reset: true)
  end
end
