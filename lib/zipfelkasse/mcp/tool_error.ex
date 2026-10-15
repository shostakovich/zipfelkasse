defmodule Zipfelkasse.MCP.ToolError do
  @moduledoc "A tool call refused for its arguments; the message goes back to the client."

  defexception [:message]

  @doc "Raises a refusal with `message`."
  @spec raise!(String.t()) :: no_return()
  def raise!(message), do: raise(__MODULE__, message: message)
end
