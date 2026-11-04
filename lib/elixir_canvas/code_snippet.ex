defmodule ElixirCanvas.CodeSnippet do
  @moduledoc """
  Literal UTF-8 source stored only on version-2 code nodes.

  Validation preserves source and unknown metadata. Quotas count decoded UTF-8
  bytes, including duplicate nodes, independently of embedded attachments.
  """

  alias Hakushi.{Graph, Node}

  @source_limit 262_144
  @total_limit 1_048_576
  @binary_controls ~r/[\x{0000}-\x{0008}\x{000B}\x{000C}\x{000E}-\x{001F}\x{007F}-\x{009F}]/u

  def source_limit, do: @source_limit
  def total_limit, do: @total_limit

  @doc "Validates code data without normalizing its source or language."
  @spec validate(term()) :: :ok | {:error, String.t()}
  def validate(%{} = data) do
    cond do
      Map.has_key?(data, "attachment") or Map.has_key?(data, :attachment) ->
        {:error, "Code nodes cannot carry attachments."}

      Map.has_key?(data, "language") and
          (not is_binary(data["language"]) or data["language"] == "" or
             not String.valid?(data["language"])) ->
        {:error, "Code language must be a nonempty UTF-8 string or omitted for Auto."}

      true ->
        validate_content(data["content"])
    end
  end

  def validate(_data), do: {:error, "Code needs a data object with string content."}

  @doc "Validates code sources and their duplicate-inclusive graph byte quota."
  @spec validate_graph(Graph.t() | [Node.t() | map()]) :: :ok | {:error, String.t()}
  def validate_graph(%Graph{nodes: nodes}), do: validate_nodes(nodes)
  def validate_graph(nodes) when is_list(nodes), do: validate_nodes(nodes)
  def validate_graph(_graph), do: {:error, "Code snippets need a canvas graph or node list."}

  defp validate_nodes(nodes) do
    case Enum.reduce_while(nodes, 0, &accumulate/2) do
      total when is_integer(total) -> :ok
      error -> error
    end
  end

  defp accumulate({_id, node}, total), do: accumulate(node, total)

  defp accumulate(%{} = node, total) do
    if Node.get(node, :type, nil) == "code" do
      data = Node.get(node, :data, %{})

      with :ok <- validate(data) do
        total = total + byte_size(data["content"])

        if total <= @total_limit,
          do: {:cont, total},
          else:
            {:halt,
             {:error, "Code sources must total #{@total_limit} bytes (1 MiB) or less per canvas."}}
      else
        error -> {:halt, error}
      end
    else
      {:cont, total}
    end
  end

  defp accumulate(_node, total), do: {:cont, total}

  defp validate_content(content) when is_binary(content) do
    cond do
      byte_size(content) > @source_limit ->
        {:error, "Code source must be #{@source_limit} bytes (256 KiB) or fewer."}

      not String.valid?(content) ->
        {:error, "Code source must be valid UTF-8 text."}

      Regex.match?(@binary_controls, content) ->
        {:error,
         "Code source cannot contain binary control characters; tab, LF, and CR are allowed."}

      true ->
        :ok
    end
  end

  defp validate_content(_content),
    do: {:error, "Code needs string content containing UTF-8 source."}
end
