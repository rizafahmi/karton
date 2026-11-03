defmodule ElixirCanvasWeb.DrawingCanvas do
  @moduledoc """
  Local drawing canvas adapter. Hakushi owns ordinary edits and their history;
  order entries share that same history because Hakushi has no reorder change.
  Text imports use Hakushi's native add/history path; on-demand reads never edit.
  """
  use ElixirCanvasWeb, :live_component

  alias ElixirCanvas.Attachment
  alias Hakushi.{Canvas, Graph}

  @connector_options %{
    "stroke" => ~w(none ink surface accent gray blue green yellow red violet),
    "width" => [1, 2, 4],
    "dash" => [true, false]
  }

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
  def render(assigns) do
    styles =
      Map.new(Graph.edges(assigns.graph), fn edge ->
        style = Map.get(edge.data, "connector_style")

        supported =
          if is_map(style) do
            Map.new(
              for {key, values} <- @connector_options,
                  Map.has_key?(style, key) and style[key] in values,
                  do: {key, style[key]}
            )
          else
            %{}
          end

        {edge.id, supported}
      end)

    assigns
    |> assign(:rest, Map.put(assigns.rest, :"data-connector-styles", Jason.encode!(styles)))
    |> Canvas.render()
  end

  @impl true
  def handle_event("hakushi:draw", %{"tool" => "drawing:attachment"} = params, socket) do
    with :ok <- validate_attachment_import(params, socket),
         :ok <- Attachment.validate(params["attachment"]) do
      case Canvas.handle_event("hakushi:draw", params, socket) do
        {:reply, %{"ok" => true} = reply, socket} ->
          {:reply, reply, socket}

        {:reply, reply, socket} ->
          reply =
            reply
            |> Map.put("ok", false)
            |> Map.put_new("error", "The attachment was refused; nothing was added.")

          {:reply, reply, socket}
      end
    else
      {:error, reason} -> attachment_error(reason, socket)
    end
  end

  def handle_event(
        "drawing:attachment-read",
        %{"generation" => generation, "node" => id},
        socket
      )
      when is_integer(generation) and is_binary(id) do
    if generation != socket.assigns.generation do
      attachment_error("This attachment request belongs to an older canvas.", socket)
    else
      case Graph.node(socket.assigns.graph, id) do
        %{type: "shape", data: %{"attachment" => attachment}} ->
          case Attachment.validate(attachment) do
            :ok -> {:reply, %{"ok" => true, "attachment" => attachment}, socket}
            {:error, reason} -> attachment_error(reason, socket)
          end

        _node ->
          attachment_error("This node has no text attachment.", socket)
      end
    end
  end

  def handle_event("drawing:attachment-read", _params, socket),
    do: attachment_error("Attachment reads need the current generation and a node id.", socket)

  def handle_event(
        "drawing:edge-style",
        %{"edges" => ids, "key" => key, "value" => value},
        socket
      )
      when is_list(ids) and ids != [] and length(ids) <= 1_000 do
    edges = Enum.map(Enum.uniq(ids), &Graph.edge(socket.assigns.graph, &1))

    cond do
      socket.assigns.readonly ->
        {:reply, %{"error" => "This canvas is read-only."}, socket}

      value not in Map.get(@connector_options, key, []) or Enum.any?(edges, &is_nil/1) ->
        {:reply, %{"error" => "Invalid connector style command."}, socket}

      Enum.any?(edges, fn edge ->
        Map.has_key?(edge.data, "connector_style") and
            not is_map(edge.data["connector_style"])
      end) ->
        {:reply,
         %{"error" => "Connector style conflicts with existing metadata; nothing was changed."},
         socket}

      true ->
        updates =
          for edge <- edges,
              style = Map.get(edge.data, "connector_style", %{}),
              Map.get(style, key, edge_default(edge, key)) != value do
            %{
              id: edge.id,
              data: Map.put(edge.data, "connector_style", Map.put(style, key, value))
            }
          end

        case updates do
          [] ->
            {:reply, %{"ok" => true}, socket}

          _ ->
            inverse =
              Hakushi.Change.update(
                edges:
                  Enum.map(updates, fn %{id: id} ->
                    %{id: id, data: Graph.edge(socket.assigns.graph, id).data}
                  end)
              )

            graph = socket.assigns.graph
            change = Hakushi.Change.update(edges: updates)
            {:ok, socket} = Canvas.update(%{hakushi_change: change}, socket)

            if socket.assigns.graph == graph do
              {:reply, %{"error" => socket.assigns.notice || "Connector style was refused."},
               socket}
            else
              socket =
                assign(socket, undo: Enum.take([inverse | socket.assigns.undo], 100), redo: [])

              {:reply, %{"ok" => true}, socket}
            end
        end
    end
  end

  def handle_event("drawing:edge-style", _params, socket),
    do: {:reply, %{"error" => "Invalid connector style command."}, socket}

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
    send(self(), {:canvas_changed, socket.assigns.generation, graph})

    socket
    |> assign(:graph, graph)
    |> stream(:nodes, Graph.nodes(graph), reset: true)
  end

  defp validate_attachment_import(params, socket) do
    cond do
      not is_integer(params["generation"]) or
          params["generation"] != socket.assigns.generation ->
        {:error, "This attachment import belongs to an older canvas."}

      socket.assigns.readonly ->
        {:error, "This canvas is read-only."}

      params["parent"] != nil ->
        {:error, "Attachment imports cannot be placed in groups."}

      not attachment_box?(params["box"]) ->
        {:error, "Attachment imports need a numeric box with positive dimensions."}

      true ->
        :ok
    end
  end

  defp attachment_box?([x, y, width, height]),
    do:
      is_number(x) and is_number(y) and is_number(width) and is_number(height) and
        width > 0 and height > 0

  defp attachment_box?(_box), do: false

  defp attachment_error(reason, socket),
    do: {:reply, %{"ok" => false, "error" => reason}, socket}

  defp edge_default(_edge, "stroke"), do: nil
  defp edge_default(_edge, "width"), do: 2
  defp edge_default(edge, "dash"), do: edge.animated
  defp edge_default(_edge, _key), do: nil
end
