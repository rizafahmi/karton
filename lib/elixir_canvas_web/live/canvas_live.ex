defmodule ElixirCanvasWeb.CanvasLive do
  @moduledoc """
  LiveView workspace for editing local version-1 JSON canvases.

  Coordinates Hakushi graph operations, portable drawing typography and color
  roles, dirty/conflict tracking, and persistence across server file paths,
  browser File System Access handles, copy-download fallbacks, and explicit copies
  that leave the open document's source, save baseline, and edits untouched.
  """
  use ElixirCanvasWeb, :live_view

  alias ElixirCanvas.{Attachment, Document}
  alias ElixirCanvasWeb.DrawingShapes

  @impl true
  def mount(_params, _session, socket) do
    path = System.get_env("CANVAS_FILE") || Path.expand("examples/welcome.json")
    if connected?(socket), do: Process.send_after(self(), :check_file, 1_000)

    socket =
      assign(socket,
        page_title: "Canvas",
        document: nil,
        graph: nil,
        path_input: path,
        drawing_font: "sans",
        dirty: false,
        disk_status: :unchanged,
        error: nil,
        notice: nil,
        notice_id: nil,
        dismissed_notice_id: nil,
        dismissed_error: nil,
        dismissed_disk_status: nil,
        generation: 0,
        edit_version: 0,
        pending_save: nil,
        file_menu_open: false,
        style_open: false
      )

    {:ok, load_document(socket, path)}
  end

  def handle_event("new", params, socket) do
    cond do
      params["generation"] != socket.assigns.generation ->
        {:reply, %{ok: false}, socket}

      socket.assigns.pending_save ->
        {:reply, %{ok: false}, assign(socket, error: "Wait for the current file save to finish.")}

      socket.assigns.dirty ->
        {:reply, %{ok: false},
         assign(socket, error: "Save or reload this canvas before starting a new canvas.")}

      true ->
        socket = put_document(socket, Document.new())
        {:reply, %{ok: true, generation: socket.assigns.generation}, socket}
    end
  end

  def handle_event("rename_document", params, socket) do
    cond do
      params["generation"] != to_string(socket.assigns.generation) ->
        {:noreply, socket}

      socket.assigns.pending_save ->
        {:noreply, assign(socket, error: "Wait for the current file save to finish.")}

      socket.assigns.document == nil ->
        {:noreply, socket}

      true ->
        case Document.rename(socket.assigns.document, params["filename"]) do
          {:ok, document} ->
            {:noreply,
             assign(socket,
               document: document,
               page_title: document.filename,
               error: nil,
               notice: nil
             )}

          {:error, reason} ->
            {:noreply, assign(socket, error: reason)}
        end
    end
  end

  @impl true
  def handle_event("open", %{"path" => path}, socket) do
    cond do
      socket.assigns.pending_save ->
        {:noreply, assign(socket, error: "Wait for the current file save to finish.")}

      socket.assigns.dirty ->
        {:noreply,
         assign(socket, error: "Save or reload this canvas before opening another file.")}

      true ->
        {:noreply, load_document(socket, path)}
    end
  end

  def handle_event("create", %{"path" => path}, socket) do
    cond do
      socket.assigns.pending_save ->
        {:noreply, assign(socket, error: "Wait for the current file save to finish.")}

      socket.assigns.dirty ->
        {:noreply,
         assign(socket, error: "Save or reload this canvas before creating another file.")}

      true ->
        case Document.create(path) do
          {:ok, document} -> {:noreply, put_document(socket, document)}
          {:error, reason} -> {:noreply, assign(socket, error: reason)}
        end
    end
  end

  def handle_event("selected-open", params, socket) do
    cond do
      params["generation"] != socket.assigns.generation ->
        {:reply, %{ok: false}, socket}

      socket.assigns.pending_save ->
        {:reply, %{ok: false}, assign(socket, error: "Wait for the current file save to finish.")}

      socket.assigns.dirty ->
        {:reply, %{ok: false},
         assign(socket, error: "Save or reload this canvas before opening another file.")}

      true ->
        load_selected(socket, params)
    end
  end

  def handle_event("selected-reload", params, socket) do
    document = socket.assigns.document

    cond do
      !document || document.persistence == :server_file ||
        params["generation"] != socket.assigns.generation ||
          (document.revision != nil && params["filename"] != document.filename) ->
        {:reply, %{ok: false}, socket}

      socket.assigns.pending_save ->
        {:reply, %{ok: false}, assign(socket, error: "Wait for the current file save to finish.")}

      params["edit_version"] != socket.assigns.edit_version ->
        {:reply, %{ok: false},
         assign(socket,
           error:
             "Canvas changed while the file was being read. Reload again to discard those edits."
         )}

      true ->
        load_selected(socket, params)
    end
  end

  def handle_event("save", _params, %{assigns: %{document: nil}} = socket),
    do: {:reply, %{ok: false}, socket}

  def handle_event("save", params, socket) do
    cond do
      socket.assigns.pending_save ->
        {:reply, %{ok: false}, assign(socket, error: "Wait for the current file save to finish.")}

      Map.get(params, "generation", socket.assigns.generation) != socket.assigns.generation ->
        {:reply, %{ok: false}, socket}

      socket.assigns.document.persistence == :server_file ->
        save_server_document(socket)

      params["generation"] == socket.assigns.generation ->
        prepare_selected_save(socket, params)

      true ->
        {:reply, %{ok: false},
         assign(socket, error: "Use the Save button to save the selected file on this device.")}
    end
  end

  def handle_event("save-copy", _params, %{assigns: %{document: nil}} = socket),
    do: {:reply, %{ok: false}, socket}

  def handle_event("save-copy", params, socket) do
    cond do
      not is_integer(params["generation"]) ||
          params["generation"] != socket.assigns.generation ->
        {:reply, %{ok: false}, socket}

      socket.assigns.pending_save ->
        {:reply, %{ok: false}, socket}

      true ->
        prepare_document_copy(socket)
    end
  end

  def handle_event("selected-saved", %{"token" => token, "generation" => generation}, socket) do
    case socket.assigns.pending_save do
      %{
        intent: :save,
        token: ^token,
        generation: ^generation,
        document: %{persistence: :browser_file} = document
      } ->
        dirty =
          socket.assigns.graph != document.graph or
            socket.assigns.drawing_font != Document.drawing_font(document)

        {:reply, %{ok: true},
         assign(socket,
           document: document,
           page_title: document.filename,
           pending_save: nil,
           dirty: dirty,
           disk_status: :unchanged,
           error: nil,
           notice: if(dirty, do: nil, else: "Saved to disk")
         )}

      _ ->
        {:reply, %{ok: false}, socket}
    end
  end

  def handle_event(
        "selected-copy-downloaded",
        %{"token" => token, "generation" => generation},
        socket
      ) do
    case socket.assigns.pending_save do
      %{intent: :copy, token: ^token, generation: ^generation}
      when generation == socket.assigns.generation ->
        {:reply, %{ok: true},
         assign(socket,
           pending_save: nil,
           notice_id: token,
           notice:
             "Copy download started; the original file and unsaved status are unchanged. Disk persistence is not confirmed."
         )}

      %{
        intent: :save,
        token: ^token,
        generation: ^generation,
        document: %{persistence: :save_copy}
      } ->
        {:reply, %{ok: true},
         assign(socket,
           document:
             if(socket.assigns.document.persistence == :untitled,
               do: %{socket.assigns.document | persistence: :save_copy},
               else: socket.assigns.document
             ),
           pending_save: nil,
           notice_id: token,
           dirty: socket.assigns.dirty || socket.assigns.document.persistence == :untitled,
           error: nil,
           notice:
             if(socket.assigns.document.revision == nil,
               do:
                 "Copy download started; disk persistence is not confirmed. Use Reload: choose file again… to open a saved copy.",
               else:
                 "Copy download started; original file not changed. Disk persistence is not confirmed."
             )
         )}

      _ ->
        {:reply, %{ok: false}, socket}
    end
  end

  def handle_event(
        "selected-save-error",
        %{"token" => token, "generation" => generation} = params,
        socket
      ) do
    case socket.assigns.pending_save do
      %{intent: :copy, token: ^token, generation: ^generation}
      when generation == socket.assigns.generation ->
        socket = socket |> assign(pending_save: nil) |> copy_error(params["message"])
        {:reply, %{ok: false}, socket}

      %{intent: :save, token: ^token, generation: ^generation} ->
        status =
          case {socket.assigns.document.persistence, params["status"]} do
            {:browser_file, "changed"} -> :changed
            {:browser_file, "unavailable"} -> :unavailable
            _ -> socket.assigns.disk_status
          end

        {:reply, %{ok: false},
         assign(socket,
           pending_save: nil,
           error: params["message"],
           dismissed_error: nil,
           dismissed_disk_status: nil,
           notice: nil,
           disk_status: status
         )}

      _ ->
        {:reply, %{ok: false}, socket}
    end
  end

  def handle_event(
        "selected-error",
        %{"generation" => generation, "action" => "save-copy", "message" => message},
        socket
      )
      when is_binary(message) do
    if generation == socket.assigns.generation,
      do: {:noreply, copy_error(socket, message)},
      else: {:noreply, socket}
  end

  def handle_event("selected-error", %{"generation" => generation, "message" => message}, socket)
      when is_binary(message) do
    if generation == socket.assigns.generation do
      {:noreply, assign(socket, error: message, dismissed_error: nil, notice: nil)}
    else
      {:noreply, socket}
    end
  end

  def handle_event("reload", _params, %{assigns: %{document: nil}} = socket),
    do: {:noreply, socket}

  def handle_event("reload", _params, socket) do
    cond do
      socket.assigns.pending_save ->
        {:noreply, assign(socket, error: "Wait for the current file save to finish.")}

      socket.assigns.document.persistence == :server_file ->
        {:noreply, load_document(socket, socket.assigns.document.path)}

      true ->
        {:noreply,
         assign(socket, error: "Use Reload to read the selected file again on this device.")}
    end
  end

  def handle_event("appearance", %{"font" => font}, socket)
      when font in ["sans", "heading", "mono", "handwritten"] do
    if socket.assigns.document do
      dirty =
        font != Document.drawing_font(socket.assigns.document) or
          socket.assigns.graph != socket.assigns.document.graph or
          (socket.assigns.document.persistence == :save_copy &&
             socket.assigns.document.revision == nil)

      {:noreply,
       assign(socket,
         drawing_font: font,
         dirty: dirty,
         notice: nil,
         edit_version:
           socket.assigns.edit_version + if(font != socket.assigns.drawing_font, do: 1, else: 0)
       )}
    else
      {:noreply, socket}
    end
  end

  def handle_event("toggle-file-menu", _params, socket),
    do:
      {:noreply,
       assign(socket, file_menu_open: !socket.assigns.file_menu_open, style_open: false)}

  def handle_event("close-file-menu", _params, socket),
    do: {:noreply, assign(socket, :file_menu_open, false)}

  def handle_event("toggle-style", _params, socket),
    do: {:noreply, assign(socket, style_open: !socket.assigns.style_open, file_menu_open: false)}

  def handle_event("close-overlays", _params, socket),
    do: {:noreply, assign(socket, file_menu_open: false, style_open: false)}

  def handle_event("dismiss-feedback", %{"generation" => generation} = params, socket) do
    socket =
      if generation == to_string(socket.assigns.generation) do
        case params do
          %{"kind" => "notice", "id" => id} when id == socket.assigns.notice_id ->
            assign(socket, dismissed_notice_id: id)

          %{"kind" => "error", "message" => error} when error == socket.assigns.error ->
            assign(socket, dismissed_error: error)

          %{"kind" => "disk", "status" => status} ->
            if status == to_string(socket.assigns.disk_status),
              do: assign(socket, dismissed_disk_status: socket.assigns.disk_status),
              else: socket

          _ ->
            socket
        end
      else
        socket
      end

    {:noreply, socket}
  end

  def handle_event("show-feedback", _params, socket),
    do: {:noreply, assign(socket, dismissed_error: nil, dismissed_disk_status: nil)}

  def handle_event("client-error", params, socket) when is_map(params) do
    :telemetry.execute(
      [:elixir_canvas, :client, :error],
      %{count: 1},
      %{params: params, socket: socket, view: __MODULE__}
    )

    {:noreply, socket}
  end

  @impl true
  def handle_info({:canvas_changed, generation, graph}, socket)
      when generation == socket.assigns.generation do
    dirty =
      graph != socket.assigns.document.graph or
        socket.assigns.drawing_font != Document.drawing_font(socket.assigns.document) or
        (socket.assigns.document.persistence == :save_copy &&
           socket.assigns.document.revision == nil)

    {:noreply,
     assign(socket,
       graph: graph,
       dirty: dirty,
       notice: nil,
       edit_version:
         socket.assigns.edit_version + if(graph != socket.assigns.graph, do: 1, else: 0)
     )}
  end

  def handle_info({:canvas_changed, _generation, _graph}, socket), do: {:noreply, socket}

  def handle_info(:check_file, socket) do
    Process.send_after(self(), :check_file, 1_000)

    status =
      case socket.assigns.document do
        %{persistence: :server_file} = document -> Document.status(document)
        _ -> socket.assigns.disk_status
      end

    {:noreply,
     assign(socket,
       disk_status: status,
       dismissed_disk_status:
         if(status == socket.assigns.disk_status,
           do: socket.assigns.dismissed_disk_status,
           else: nil
         )
     )}
  end

  defp accept_change(change, %{result: graph}, generation) do
    invalid =
      change.op in [:add, :connect, :reconnect] and
        Enum.any?(change.edges, fn changed ->
          edge = Map.get(graph.edges, changed.id)
          edge && edge.source == edge.target && edge.source_handle == edge.target_handle
        end)

    attachment_result =
      if (change.op in [:add, :connect] and change.nodes != []) or
           (change.op == :update and
              Enum.any?(change.nodes, &(Map.has_key?(&1, :data) or Map.has_key?(&1, :type)))) do
        Attachment.validate_graph(graph)
      else
        :ok
      end

    cond do
      invalid ->
        {:error, "Choose a different connection handle on this item."}

      attachment_result != :ok ->
        attachment_result

      true ->
        send(self(), {:canvas_changed, generation, graph})
        :ok
    end
  end

  defp load_selected(socket, %{"mode" => mode, "filename" => filename, "bytes" => bytes})
       when mode in ["browser_file", "save_copy"] and is_binary(filename) and filename != "" and
              is_binary(bytes) do
    persistence = if mode == "browser_file", do: :browser_file, else: :save_copy

    case Document.open_selected(filename, bytes, persistence) do
      {:ok, document} ->
        socket = put_document(socket, document)

        {:reply,
         %{ok: true, generation: socket.assigns.generation, revision: revision_hex(document)},
         socket}

      {:error, reason} ->
        {:reply, %{ok: false}, assign(socket, error: reason, notice: nil)}
    end
  end

  defp load_selected(socket, _params) do
    {:reply, %{ok: false},
     assign(socket, error: "Choose a canvas JSON file using Open.", notice: nil)}
  end

  defp save_server_document(socket) do
    socket = assign(socket, dismissed_error: nil)
    document = with_drawing_font(socket.assigns.document, socket.assigns.drawing_font)

    case Document.save(document, socket.assigns.graph) do
      {:ok, document} ->
        {:reply, %{ok: true},
         assign(socket,
           document: document,
           dirty: false,
           disk_status: :unchanged,
           error: nil,
           notice: "Saved to disk"
         )}

      {:error, reason} ->
        {:reply, %{ok: false}, assign(socket, error: reason, notice: nil)}
    end
  end

  defp prepare_selected_save(socket, params) do
    document = with_drawing_font(socket.assigns.document, socket.assigns.drawing_font)

    document =
      if document.persistence == :untitled do
        case {params["mode"], params["filename"]} do
          {"browser_file", filename} when is_binary(filename) and filename != "" ->
            %{document | persistence: :browser_file, filename: filename}

          {"save_copy", filename} when filename == document.filename ->
            %{document | persistence: :save_copy}

          _ ->
            document
        end
      else
        document
      end

    case if(document.persistence == :untitled,
           do: {:error, "Choose a destination with Save before saving this untitled canvas."},
           else: Document.prepare_save(document, socket.assigns.graph)
         ) do
      {:ok, bytes, pending_document} ->
        token = Base.url_encode64(:crypto.strong_rand_bytes(16), padding: false)
        generation = socket.assigns.generation

        pending = %{
          intent: :save,
          token: token,
          generation: generation,
          document: pending_document
        }

        {:reply,
         %{
           ok: true,
           token: token,
           generation: generation,
           bytes: bytes,
           revision: revision_hex(socket.assigns.document),
           saved_revision: revision_hex(pending_document),
           mode: Atom.to_string(document.persistence),
           filename: document.filename
         }, assign(socket, pending_save: pending, error: nil, dismissed_error: nil, notice: nil)}

      {:error, reason} ->
        {:reply, %{ok: false}, assign(socket, error: reason, notice: nil)}
    end
  end

  defp prepare_document_copy(socket) do
    document = with_drawing_font(socket.assigns.document, socket.assigns.drawing_font)

    case Document.prepare_save(document, socket.assigns.graph) do
      {:ok, bytes, _snapshot} ->
        token = Base.url_encode64(:crypto.strong_rand_bytes(16), padding: false)
        generation = socket.assigns.generation
        pending = %{intent: :copy, token: token, generation: generation}

        {:reply,
         %{
           ok: true,
           token: token,
           generation: generation,
           bytes: bytes,
           filename: copy_filename(document.filename)
         }, assign(socket, pending_save: pending, notice: nil)}

      {:error, reason} ->
        {:reply, %{ok: false}, copy_error(socket, reason)}
    end
  end

  defp copy_filename(filename) do
    extension = Path.extname(filename)

    stem =
      if String.downcase(extension) == ".json",
        do: Path.rootname(filename, extension),
        else: filename

    stem <> "-copy.json"
  end

  defp copy_error(socket, reason) do
    error =
      if socket.assigns.error && socket.assigns.error != reason,
        do: "#{socket.assigns.error} #{reason}",
        else: reason

    assign(socket, error: error, notice: nil)
  end

  defp revision_hex(%{revision: nil}), do: nil
  defp revision_hex(document), do: Base.encode16(document.revision, case: :lower)

  defp load_document(socket, path) do
    case Document.open(path) do
      {:ok, document} ->
        put_document(socket, document)

      {:error, reason} ->
        assign(socket, error: reason, path_input: path, file_menu_open: true, notice: nil)
    end
  end

  defp put_document(socket, document) do
    assign(socket,
      page_title: document.filename,
      document: document,
      graph: document.graph,
      path_input: document.path || socket.assigns.path_input,
      drawing_font: Document.drawing_font(document),
      dirty: false,
      disk_status: :unchanged,
      error: nil,
      notice: nil,
      notice_id: nil,
      dismissed_notice_id: nil,
      dismissed_error: nil,
      dismissed_disk_status: nil,
      file_menu_open: false,
      style_open: false,
      generation: socket.assigns.generation + 1,
      edit_version: socket.assigns.edit_version + 1,
      pending_save: nil
    )
  end

  defp with_drawing_font(document, font) do
    if Document.drawing_font(document) == font do
      document
    else
      appearance = document.source |> Map.get("appearance", %{}) |> Map.put("font", font)
      %{document | source: Map.put(document.source, "appearance", appearance)}
    end
  end

  defp status_text(document, dirty, disk_status, error, notice) do
    cond do
      disk_status == :changed -> "Changed on disk"
      disk_status == :unavailable -> "File unavailable"
      error -> "File error"
      dirty -> "Unsaved changes"
      notice == "Saved to disk" -> notice
      document && document.persistence == :untitled -> "Not saved"
      document && document.persistence == :save_copy && document.revision == nil -> "Not saved"
      document && document.persistence == :save_copy -> "Opened copy"
      document && document.persistence == :browser_file -> "Selected file open"
      document -> "Saved locally"
      true -> "No file open"
    end
  end

  attr :name, :string, required: true
  attr :class, :string, default: ""

  defp glyph(assigns) do
    paths = %{
      "file" => "M5 3H14L19 8V21H5V3ZM13 3V9H19M8 13H15M8 17H13",
      "file-plus" => "M5 3H14L19 8V12M13 3V9H19M11 21H5V3M17 15V21M14 18H20",
      "chevron" => "M8 10L12 14L16 10",
      "save" => "M4 3H17L21 7V21H3V3H4ZM7 3V9H16V3M7 21V14H17V21",
      "style" => "M4 7H20M4 17H20M9 4V10M15 14V20",
      "close" => "M6 6L18 18M18 6L6 18"
    }

    assigns = assign(assigns, :path, Map.fetch!(paths, assigns.name))

    ~H"""
    <svg class={@class} width="20" height="20" viewBox="0 0 24 24" fill="none" aria-hidden="true">
      <path
        d={@path}
        stroke="currentColor"
        stroke-width="1.5"
        stroke-linecap="round"
        stroke-linejoin="round"
      />
    </svg>
    """
  end

  @impl true
  def render(assigns) do
    assigns =
      assign(assigns,
        problem: assigns.error != nil || assigns.disk_status != :unchanged,
        error_visible: assigns.error != nil && assigns.dismissed_error != assigns.error,
        disk_visible:
          assigns.document != nil && assigns.disk_status != :unchanged &&
            assigns.dismissed_disk_status != assigns.disk_status,
        notice_visible:
          assigns.document != nil && assigns.notice != nil && assigns.notice != "Saved to disk" &&
            assigns.dismissed_notice_id != assigns.notice_id
      )

    ~H"""
    <main
      id="workspace"
      class="canvas-workspace"
      phx-hook="Workspace"
      data-dirty={to_string(@dirty)}
      data-drawing-font={@drawing_font}
      data-file-mode={if @document, do: Atom.to_string(@document.persistence), else: "none"}
      data-file-name={if @document, do: @document.filename, else: ""}
      data-source-missing={to_string(@document != nil && @document.revision == nil)}
      data-generation={@generation}
      data-edit-version={@edit_version}
      data-file-busy={to_string(@pending_save != nil)}
      data-style-open={to_string(@style_open)}
      data-font-state="loading"
      data-zen-mode="false"
      data-attachment-file-limit={Attachment.file_limit()}
      data-attachment-total-limit={Attachment.total_limit()}
    >
      <input
        id="canvas-file-input"
        class="sr-only"
        type="file"
        accept=".json,application/json"
        aria-label="Canvas JSON file"
        tabindex="-1"
        phx-update="ignore"
      />
      <input
        id="attachment-file-input"
        class="sr-only"
        type="file"
        aria-label="Text attachment file"
        tabindex="-1"
        phx-update="ignore"
      />
      <p :if={@document && @document.persistence == :save_copy} id="save-copy-help" class="sr-only">
        Downloads a JSON copy without confirming disk persistence. Use Reload: choose file again… to load the copy you saved; cancelling keeps your current edits.
      </p>
      <p :if={@document} id="save-document-copy-help" class="sr-only">
        Download a separate JSON file. This canvas keeps its source and unsaved changes; disk persistence is not confirmed.
      </p>
      <section :if={@document} class="canvas-area" aria-label="Canvas workspace">
        <.live_component
          module={ElixirCanvasWeb.DrawingCanvas}
          id={"board-#{@generation}"}
          graph={@graph}
          kits={[DrawingShapes]}
          rules={[loops: true]}
          on_change={fn change, context -> accept_change(change, context, @generation) end}
          generation={@generation}
          background={:none}
          papers={true}
          minimap={false}
          export={true}
          fit={true}
          label="Spatial thinking canvas"
          class="drawing-board"
        />
      </section>

      <header class="canvas-header">
        <div class="document-identity">
          <button
            id="file-menu-toggle"
            class="document-toggle"
            phx-click="toggle-file-menu"
            aria-label="Document menu"
            aria-expanded={to_string(@file_menu_open)}
            aria-controls="file-menu"
          >
            <.glyph name="file" />
            <span class="document-name">
              {if @document, do: @document.filename, else: "Open a canvas"}
            </span>
            <.glyph name="chevron" />
          </button>
        </div>
        <div class="canvas-actions">
          <div class="save-feedback">
            <button
              :if={@problem}
              id="save-status"
              type="button"
              class="document-status conflict"
              phx-click="show-feedback"
              aria-controls="canvas-messages"
              aria-expanded={to_string(@error_visible || @disk_visible)}
              title="Show file problem details"
            >
              <span class="status-dot"></span>
              {status_text(@document, @dirty, @disk_status, @error, @notice)}
            </button>
            <span
              :if={!@problem}
              id="save-status"
              class={["document-status", @dirty && "unsaved"]}
              role="status"
            >
              <span class="status-dot"></span>
              {status_text(@document, @dirty, @disk_status, @error, @notice)}
            </span>
            <span id="thought-draft-status" class="document-status unsaved" role="status">
              <span class="status-dot"></span> Thought draft — not added
            </span>
          </div>
          <button
            id="save-file"
            class="save-button"
            aria-keyshortcuts="Meta+S Control+S"
            phx-click={JS.dispatch("canvas:save", to: "#workspace")}
            disabled={!@document || @pending_save != nil}
            title={
              if @document && @document.persistence == :save_copy,
                do: "Download a copy (⌘S / Ctrl+S); disk persistence is not confirmed",
                else: "Save (⌘S / Ctrl+S)"
            }
            aria-describedby={@document && @document.persistence == :save_copy && "save-copy-help"}
          >
            <.glyph name="save" />
            <span>
              {if @document && @document.persistence == :save_copy, do: "Save copy", else: "Save"}
            </span>
          </button>
        </div>
      </header>

      <div :if={@document} class="drawing-dock" role="group" aria-label="Drawing appearance">
        <button
          id="style-toggle"
          class="style-button"
          phx-click="toggle-style"
          aria-label="Object styles"
          aria-pressed={to_string(@style_open)}
          aria-expanded={to_string(@style_open)}
          aria-controls={"board-#{@generation}-style-inspector"}
        >
          <.glyph name="style" /><span>Style</span>
        </button>
      </div>
      <button
        :if={@document}
        id="exit-zen-mode"
        type="button"
        class="zen-exit-control"
        data-zen-toggle
        phx-click={JS.dispatch("canvas:exit-zen", to: "#workspace")}
        title="Exit Zen mode (Shift+Z)"
        aria-keyshortcuts="Shift+Z"
      >
        Exit Zen
      </button>

      <section
        :if={@file_menu_open}
        id="file-menu"
        class="file-menu"
        aria-label="Local document"
        phx-click-away="close-file-menu"
      >
        <h2 class="menu-heading">Your canvas, your file.</h2>
        <p :if={@document && @document.path} class="file-location" title={@document.path}>
          {@document.path}
        </p>
        <p :if={@document && !@document.path} id="selected-file-help" class="menu-footnote">
          {cond do
            @document.persistence == :browser_file ->
              "Selected on this device. Save writes this file; Reload reads it again."

            @document.persistence == :untitled || @document.revision == nil ->
              "Not saved yet. Save chooses a JSON file on supported browsers; otherwise Save copy downloads #{@document.filename}. Reload asks you to select an actual saved copy."

            true ->
              "Opened as a copy. Save copy downloads JSON; it cannot overwrite the original. Reload asks you to select this file again."
          end}
        </p>
        <details id="keyboard-shortcuts" class="menu-section keyboard-shortcuts">
          <summary>Keyboard shortcuts (?)</summary>
          <p>Canvas focus only, not fields/IME. Mod = Command or Ctrl.</p>
          <dl>
            <dt>V R O D I</dt>
            <dd>Select, rectangle, ellipse, diamond, triangle</dd>
            <dt>T L A</dt>
            <dd>Text, line, arrow</dd>
            <dt>Enter / F2</dt>
            <dd>Enter places tool; either edits text/edge label or previews an attachment</dd>
            <dt>Tab / Shift+Tab</dt>
            <dd>Focus selected drawing first, then objects/edges; keep selection</dd>
            <dt>Space</dt>
            <dd>Tap toggles selection; hold+drag pans</dd>
            <dt>Mod+A / Alt+arrows</dt>
            <dd>Select all / nearest object</dd>
            <dt>Arrows / Shift</dt>
            <dd>Move 1/10px; pan without selection</dd>
            <dt>G</dt>
            <dd>Geometry: Tab handle; arrows adjust; Shift ×10</dd>
            <dt>C</dt>
            <dd>Connect/reconnect: arrows/Tab choose; Enter next</dd>
            <dt>N → arrow</dt>
            <dd>
              Focused or sole selected unlocked text shape: independent thought, then type inline
            </dd>
            <dt>Enter / Escape</dt>
            <dd>Commit/cancel G/C/N; N: Shift+Enter newline</dd>
            <dt>S / ?</dt>
            <dd>Style / this reference</dd>
            <dt>Shift+Z</dt>
            <dd>Toggle Zen mode; Escape exits after active editing</dd>
            <dt>Delete / Backspace</dt>
            <dd>Delete selection</dd>
            <dt>Mod+C X V D</dt>
            <dd>Copy, cut, paste, duplicate</dd>
            <dt>Mod+Z / Mod+Shift+Z</dt>
            <dd>Undo / redo (also Ctrl+Y)</dd>
            <dt>Mod+Shift+[ / ]</dt>
            <dd>Send back / bring front</dd>
            <dt>Shift+L</dt>
            <dd>Tidy; rail picker offers all layouts</dd>
            <dt>+ − / Mod+ + −</dt>
            <dd>Canvas zoom</dd>
            <dt>Shift+1 / Shift+0</dt>
            <dd>Fit / reset (also Mod+0)</dd>
            <dt>Mod+S / Mod+O</dt>
            <dd>Save / native Open</dd>
            <dt>Mod+Shift+E</dt>
            <dd>Image Download</dd>
          </dl>
          <p>
            Save commits placed N previews (including blank); no direction cancels. Existing 2,000-character limit: full draft retained, Save/Open blocked. No automatic links. Escape exits editing before Style/file; fields and browser shortcuts stay native.
          </p>
        </details>
        <div class="menu-section">
          <div class="file-menu-actions">
            <button
              id="open-native-file"
              type="button"
              class="menu-button native-open-button"
              title="Open… (⌘O / Ctrl+O)"
              aria-keyshortcuts="Meta+O Control+O"
              phx-click={JS.dispatch("canvas:open", to: "#workspace")}
              disabled={@pending_save != nil}
              aria-describedby="native-open-help"
            >
              <.glyph name="file" />Open…
            </button>
            <button
              id="new-canvas"
              type="button"
              class="menu-button"
              phx-click={JS.dispatch("canvas:new", to: "#workspace")}
              disabled={@pending_save != nil}
            >
              <.glyph name="file-plus" />New canvas
            </button>
          </div>
          <p id="native-open-help" class="menu-footnote" data-native-open-help>
            Choose a canvas JSON file. Supported browsers can save back with your permission; other browsers download a copy.
          </p>
        </div>
        <div :if={@document} class="menu-section">
          <button
            id="zen-mode-toggle"
            type="button"
            class="menu-button"
            data-zen-toggle
            phx-click={JS.dispatch("canvas:toggle-zen", to: "#workspace")}
            aria-pressed="false"
            aria-keyshortcuts="Shift+Z"
            aria-describedby="zen-mode-help"
          >
            Zen mode
          </button>
          <p id="zen-mode-help" class="menu-footnote">
            Focus on the canvas and drawing tools. Save status and file problems stay visible.
          </p>
        </div>
        <div :if={@document} class="menu-section">
          <button
            id="attach-text-file"
            type="button"
            class="menu-button"
            phx-click={JS.dispatch("canvas:attach", to: "#workspace")}
            disabled={@pending_save != nil}
            aria-describedby="attachment-help"
          >
            <.glyph name="file-plus" />Attach text file…
          </button>
          <p id="attachment-help" class="menu-footnote">
            Embed a UTF-8 text or Markdown copy, up to 256 KiB per file and 1 MiB total. Drop a file onto the canvas, or choose one here. Original files are never synced or changed.
          </p>
        </div>
        <div :if={@document} class="menu-section">
          <div class="file-menu-actions">
            <button
              id="save-document-copy"
              type="button"
              class="menu-button"
              data-save-copy
              phx-click={JS.dispatch("canvas:save-copy", to: "#workspace")}
              disabled={@pending_save != nil}
              aria-describedby="save-document-copy-menu-help"
            >
              <.glyph name="save" />Save a copy
            </button>
          </div>
          <p id="save-document-copy-menu-help" class="menu-footnote">
            Download a separate JSON file without changing this canvas's filename, connected source, or unsaved status.
          </p>
        </div>
        <form
          :if={
            @document && @document.revision == nil && @document.path == nil &&
              @document.persistence in [:untitled, :save_copy]
          }
          id="rename-document-form"
          class="menu-section file-form rename-document-form"
          phx-submit="rename_document"
        >
          <label class="field-label" for="document-filename">Canvas filename</label>
          <p id="document-filename-help" class="menu-footnote">
            Up to 120 characters including .json; no /, backslash, .. or control characters.
            Naming does not save a file.
          </p>
          <input type="hidden" name="generation" value={@generation} />
          <div class="file-input-row">
            <input
              id="document-filename"
              name="filename"
              value={@document.filename}
              aria-describedby="document-filename-help"
              autocomplete="off"
              autocorrect="off"
              autocapitalize="off"
              spellcheck="false"
              required
              disabled={@pending_save != nil}
            />
            <button type="submit" class="menu-button" disabled={@pending_save != nil}>
              Rename
            </button>
          </div>
        </form>
        <details id="server-file-options" class="menu-section server-file-options">
          <summary>Advanced: server file path</summary>
          <p class="menu-footnote">For files on the computer running this app.</p>
          <form id="open-file-form" class="file-form" phx-submit="open">
            <label class="field-label" for="file-path">Open a server JSON file</label>
            <div class="file-input-row">
              <input
                id="file-path"
                name="path"
                value={@path_input}
                autocomplete="off"
                spellcheck="false"
                required
              />
              <button type="submit" class="menu-button" disabled={@pending_save != nil}>
                Open path
              </button>
            </div>
          </form>
          <form id="create-file-form" class="file-form" phx-submit="create">
            <label class="field-label" for="new-file-path">Create a server canvas</label>
            <div class="file-input-row">
              <input
                id="new-file-path"
                name="path"
                placeholder="/path/to/ideas.json"
                autocomplete="off"
                spellcheck="false"
                required
              />
              <button type="submit" class="menu-button" disabled={@pending_save != nil}>
                Create
              </button>
            </div>
          </form>
        </details>
        <div :if={@document} class="menu-section">
          <form id="appearance-form" phx-change="appearance">
            <label class="field-label" for="drawing-font">Default text style</label>
            <select id="drawing-font" name="font" aria-describedby="drawing-font-help">
              <option value="sans" selected={@drawing_font == "sans"}>Normal</option>
              <option value="heading" selected={@drawing_font == "heading"}>Title</option>
              <option value="mono" selected={@drawing_font == "mono"}>Code</option>
              <option value="handwritten" selected={@drawing_font == "handwritten"}>
                Handwritten
              </option>
            </select>
            <p id="drawing-font-help" class="menu-footnote">
              Used by text without its own style. Save to keep it.
            </p>
          </form>
          <button
            id="reload-file"
            class="menu-button reload-button"
            phx-click={
              if @document.persistence == :server_file,
                do: "reload",
                else: JS.dispatch("canvas:reload", to: "#workspace")
            }
            disabled={@pending_save != nil}
            data-confirm={
              @document.persistence == :server_file && @dirty &&
                "Discard unsaved canvas edits and reload the file from disk?"
            }
          >
            {if @document.persistence in [:save_copy, :untitled],
              do: "Reload: choose file again…",
              else: "Reload from disk"}
          </button>
        </div>
        <p class="menu-footnote">
          Open <strong>Keyboard shortcuts (?)</strong> above for the command map.
          Tap Space to select directly; G previews geometry; C creates or reconnects arrows;
          S opens Style. Single-letter shortcuts require canvas focus.
          Command/Ctrl +/− zooms the canvas only there; focus a control for browser zoom.
        </p>
        <p class="menu-footnote">Local JSON. No account, no hidden database.</p>
        <div class="menu-section about-section">
          <p class="about-title">Elixir Canvas</p>
          <p class="menu-footnote about-copy">
            A local-file-first spatial thinking canvas. Your JSON file is the actual document—never locked inside a database or cloud account.
          </p>
          <ul class="tech-stack" aria-label="Tech stack">
            <li>Elixir</li>
            <li>Phoenix LiveView</li>
            <li>Hakushi</li>
            <li>Neo-Acid CSS</li>
          </ul>
          <a
            href="https://github.com/rizafahmi/elixir_canvas"
            target="_blank"
            rel="noopener noreferrer"
            class="action-link about-github"
          >
            github.com/rizafahmi/elixir_canvas ↗
          </a>
        </div>
      </section>

      <a
        id="agentrouter-badge"
        href="https://agentrouter.org/register?aff=pWPV"
        target="_blank"
        rel="noopener noreferrer"
        class="agentrouter-credit"
      >
        Built with free tokens via AgentRouter ↗
      </a>

      <div
        id="canvas-messages"
        class="canvas-messages"
        phx-hook="CanvasMessages"
        popover="manual"
        data-generation={@generation}
      >
        <div
          :if={@notice_visible}
          id="file-notice"
          class="canvas-message info"
          role="status"
          data-notice-id={@notice_id}
        >
          <span>{@notice}</span>
          <button
            type="button"
            class="message-dismiss"
            phx-click="dismiss-feedback"
            phx-value-kind="notice"
            phx-value-id={@notice_id}
            phx-value-generation={@generation}
            aria-label="Dismiss notification"
          >
            <.glyph name="close" />
          </button>
        </div>
        <div :if={@error_visible} id="file-error" class="canvas-message error" role="alert">
          <span>
            <span>{@error}</span>
            <span :if={@document && @disk_status == :unchanged} class="file-menu-actions">
              <button
                id="save-error-copy"
                type="button"
                class="message-action"
                data-save-copy
                phx-click={JS.dispatch("canvas:save-copy", to: "#workspace")}
                disabled={@pending_save != nil}
                aria-describedby="save-document-copy-help"
              >
                Save a copy
              </button>
            </span>
          </span>
          <button
            type="button"
            class="message-dismiss"
            phx-click="dismiss-feedback"
            phx-value-kind="error"
            phx-value-message={@error}
            phx-value-generation={@generation}
            aria-label="Dismiss error"
          >
            <.glyph name="close" />
          </button>
        </div>
        <div
          :if={@disk_visible}
          id="disk-warning"
          class="canvas-message warning"
          role="status"
        >
          <span>
            <span>
              {if @disk_status == :changed,
                do: "The source changed outside the app. Reload before saving.",
                else:
                  "The source file is missing or unreadable. Your canvas is still here; saving is blocked."}
            </span>
            <span class="file-menu-actions">
              <button
                class="message-action"
                phx-click={
                  if @document.persistence == :server_file,
                    do: "reload",
                    else: JS.dispatch("canvas:reload", to: "#workspace")
                }
                disabled={@pending_save != nil}
                data-confirm={
                  @document.persistence == :server_file && @dirty &&
                    "Discard unsaved canvas edits and reload the file from disk?"
                }
              >
                Reload file
              </button>
              <button
                id="disk-warning-save-copy"
                type="button"
                class="message-action"
                data-save-copy
                phx-click={JS.dispatch("canvas:save-copy", to: "#workspace")}
                disabled={@pending_save != nil}
                aria-describedby="save-document-copy-help"
              >
                Save a copy
              </button>
            </span>
          </span>
          <button
            type="button"
            class="message-dismiss"
            phx-click="dismiss-feedback"
            phx-value-kind="disk"
            phx-value-status={@disk_status}
            phx-value-generation={@generation}
            aria-label="Dismiss file warning"
          >
            <.glyph name="close" />
          </button>
        </div>
      </div>

      <section :if={!@document} class="empty-state">
        <.glyph name="file" class="empty-mark" />
        <h1 class="headline-two-tone">Make room <span class="muted">for an idea.</span></h1>
        <p>Open a canvas or create a local file to begin.</p>
        <button
          id="empty-open-file"
          type="button"
          class="menu-button"
          phx-click={JS.dispatch("canvas:open", to: "#workspace")}
          aria-describedby="empty-native-open-help"
        >
          Open a canvas…
        </button>
        <p id="empty-native-open-help" data-native-open-help>
          Supported browsers can save back with your permission; other browsers download a copy.
        </p>
      </section>
      <p :if={@document} class="font-message" role="status">Loading drawing fonts…</p>
      <p :if={@document} class="font-error" role="alert">
        The local drawing fonts could not load. Reload the page to try again.
      </p>
      <p class="connection-warning" role="status">
        Connection lost. Keep this tab open; unsaved edits may be lost if the session restarts.
      </p>
    </main>
    """
  end
end
