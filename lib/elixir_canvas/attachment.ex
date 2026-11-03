defmodule ElixirCanvas.Attachment do
  @moduledoc """
  The portable UTF-8 text attachment contract stored in a shape's data.

  Validation never normalizes filenames, text, or unknown metadata. Limits count
  UTF-8 bytes, including every pasted or duplicated copy in the graph.
  """

  alias Hakushi.{Graph, Node}

  @file_limit 262_144
  @total_limit 1_048_576
  @filename_limit 255
  @binary_controls ~r/[\x{0000}-\x{0008}\x{000B}\x{000C}\x{000E}-\x{001F}\x{007F}-\x{009F}]/u

  def file_limit, do: @file_limit
  def total_limit, do: @total_limit
  def filename_limit, do: @filename_limit

  @doc "Validates one attachment without changing its authored bytes or metadata."
  @spec validate(term()) :: :ok | {:error, String.t()}
  def validate(%{} = attachment) do
    with :ok <- validate_filename(attachment["filename"]),
         :ok <- validate_media_type(attachment["media_type"]),
         :ok <- validate_encoding(attachment["encoding"]),
         :ok <- validate_content(attachment["content"]) do
      :ok
    end
  end

  def validate(_attachment), do: {:error, "Attachment must be a metadata object."}

  @doc "Validates attachments and their aggregate size in a graph or list of nodes."
  @spec validate_graph(Graph.t() | [Node.t() | map()]) :: :ok | {:error, String.t()}
  def validate_graph(%Graph{nodes: nodes}), do: validate_nodes(nodes)
  def validate_graph(nodes) when is_list(nodes), do: validate_nodes(nodes)

  def validate_graph(_graph), do: {:error, "Attachments need a canvas graph or node list."}

  defp validate_nodes(nodes) do
    case Enum.reduce_while(nodes, 0, &accumulate/2) do
      total when is_integer(total) -> :ok
      error -> error
    end
  end

  defp accumulate({_id, node}, total), do: accumulate(node, total)

  defp accumulate(%{} = node, total) do
    data = Node.get(node, :data, %{})

    case data do
      %{"attachment" => attachment} -> accumulate_attachment(node, attachment, total)
      %{attachment: attachment} -> accumulate_attachment(node, attachment, total)
      _other -> {:cont, total}
    end
  end

  defp accumulate(_node, total), do: {:cont, total}

  defp accumulate_attachment(node, attachment, total) do
    with true <- Node.get(node, :type, nil) == "shape",
         :ok <- validate(attachment) do
      total = total + byte_size(attachment["content"])

      if total <= @total_limit,
        do: {:cont, total},
        else:
          {:halt,
           {:error, "Attachments must total #{@total_limit} bytes (1 MiB) or less per canvas."}}
    else
      false -> {:halt, {:error, "Text attachments belong to shape nodes."}}
      error -> {:halt, error}
    end
  end

  defp validate_filename(filename) when is_binary(filename) do
    cond do
      byte_size(filename) > @filename_limit ->
        {:error, "Attachment filename must be #{@filename_limit} UTF-8 bytes or fewer."}

      not String.valid?(filename) ->
        {:error, "Attachment filename must be valid UTF-8."}

      String.trim(filename) == "" or filename in [".", ".."] or
        String.contains?(filename, ["/", "\\"]) or Regex.match?(~r/\p{Cc}/u, filename) ->
        {:error,
         "Attachment filename must be a nonempty basename without paths or control characters."}

      true ->
        :ok
    end
  end

  defp validate_filename(_filename), do: {:error, "Attachment needs a string filename."}

  defp validate_media_type(media_type) when media_type in ["text/plain", "text/markdown"],
    do: :ok

  defp validate_media_type(_media_type),
    do: {:error, "Attachment media type must be text/plain or text/markdown."}

  defp validate_encoding("utf-8"), do: :ok
  defp validate_encoding(_encoding), do: {:error, "Attachment encoding must be utf-8."}

  defp validate_content(content) when is_binary(content) do
    cond do
      byte_size(content) > @file_limit ->
        {:error, "Attachment content must be #{@file_limit} bytes (256 KiB) or fewer."}

      not String.valid?(content) ->
        {:error, "Attachment content must be valid UTF-8 text."}

      Regex.match?(@binary_controls, content) ->
        {:error,
         "Attachment content cannot contain binary control characters; tab, LF, and CR are allowed."}

      true ->
        :ok
    end
  end

  defp validate_content(_content), do: {:error, "Attachment content must be UTF-8 text."}
end
