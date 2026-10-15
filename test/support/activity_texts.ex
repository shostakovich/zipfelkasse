defmodule Zipfelkasse.ActivityTexts do
  @moduledoc "The texts of the activity log, as tests check them."

  alias Zipfelkasse.Activities

  @doc "The texts of all entries, newest first; `:oldest_first` turns them round."
  def activity_texts(order \\ :newest_first) do
    texts = Enum.map(Activities.list_activities(), & &1.details.text)
    if order == :oldest_first, do: Enum.reverse(texts), else: texts
  end

  @doc "The text of the newest entry."
  def last_activity, do: hd(Activities.list_activities(limit: 1)).details.text
end
