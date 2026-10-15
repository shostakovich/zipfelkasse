defmodule Zipfelkasse.Settings do
  @moduledoc "The settings of the group: its name."

  alias Zipfelkasse.{Activities, Repo}
  alias Zipfelkasse.Settings.Setting

  @default_group_name "Zipfelkasse"

  @doc "The settings."
  def get_settings, do: Repo.get(Setting, 1) || %Setting{id: 1, group_name: @default_group_name}

  @doc "The name of the group."
  def group_name, do: get_settings().group_name

  @doc "A changeset for the settings form."
  def change_settings(%Setting{} = setting, attrs \\ %{}), do: Setting.changeset(setting, attrs)

  @doc "Renames the group; logged only when the name changes."
  def update_settings(actor_id, attrs) do
    Repo.transact(fn ->
      setting = get_settings()

      with {:ok, updated} <- Repo.insert_or_update(Setting.changeset(setting, attrs)),
           {:ok, _activity} <- log_rename(actor_id, setting.group_name, updated.group_name) do
        {:ok, updated}
      end
    end)
  end

  defp log_rename(_actor_id, same, same), do: {:ok, nil}

  defp log_rename(actor_id, old, new),
    do: Activities.log_settings(actor_id, "Gruppe umbenannt: „#{old}“ → „#{new}“")
end
