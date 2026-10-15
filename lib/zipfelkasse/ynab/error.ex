defmodule Zipfelkasse.Ynab.Error do
  @moduledoc """
  A failed YNAB request. Without a status YNAB was not reached or its answer was unreadable, so
  whether it processed the request is unclear, as with a 5xx.
  """

  defexception [:status, :message, retry_after: 0]

  @type t :: %__MODULE__{}
  @type kind :: :unclear | :unauthorized | :forbidden | :not_found | :rate_limited | :rejected

  @doc "An error answer of YNAB with its `detail`; `retry_after` in seconds."
  def api(status, detail \\ nil, retry_after \\ 0) do
    message =
      case status do
        401 -> "YNAB: Token ungültig oder abgelaufen"
        429 -> "YNAB: Anfragelimit erreicht (200 pro Stunde)"
        _other -> Enum.join(["YNAB-Fehler #{status}" | List.wrap(detail)], ": ")
      end

    %__MODULE__{status: status, message: message, retry_after: retry_after}
  end

  @doc "An error after which it is unknown whether YNAB processed the request."
  def unclear(message), do: %__MODULE__{message: message}

  @doc "What the error means for a sync; anything but `:rejected` concerns the whole run."
  @spec kind(Exception.t()) :: kind() | :other
  def kind(%__MODULE__{status: nil}), do: :unclear
  def kind(%__MODULE__{status: 401}), do: :unauthorized
  def kind(%__MODULE__{status: 403}), do: :forbidden
  def kind(%__MODULE__{status: 404}), do: :not_found
  def kind(%__MODULE__{status: 429}), do: :rate_limited
  def kind(%__MODULE__{status: status}) when status >= 500, do: :unclear
  def kind(%__MODULE__{}), do: :rejected
  def kind(_exception), do: :other

  @doc "Whether the error stops the run instead of concerning a single transaction."
  def aborts_run?(error), do: kind(error) != :rejected
end
