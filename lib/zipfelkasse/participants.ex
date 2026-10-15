defmodule Zipfelkasse.Participants do
  @moduledoc """
  The people of the group. Every change is logged with the person who made it (`actor_id`, nil
  when it happened automatically).
  """

  import Ecto.Query

  alias Ecto.Changeset
  alias Zipfelkasse.{Activities, Balances, Money, Repo}
  alias Zipfelkasse.Participants.Participant

  @doc "The people, by name: `:active` (default), `:archived` or `:all`."
  def list_participants(which \\ :active) do
    Participant
    |> archived(which)
    |> order_by([p], [fragment("? COLLATE NOCASE", p.name), p.id])
    |> Repo.all()
  end

  defp archived(query, :active), do: where(query, [p], is_nil(p.archived_at))
  defp archived(query, :archived), do: where(query, [p], not is_nil(p.archived_at))
  defp archived(query, :all), do: query

  @doc "The person with `id`, or nil."
  def get_participant(id), do: Repo.get(Participant, id)

  @doc "The person with `id`; raises if there is none."
  def get_participant!(id), do: Repo.get!(Participant, id)

  @doc "A changeset for the name form."
  def change_participant(%Participant{} = participant, attrs \\ %{}),
    do: Participant.changeset(participant, attrs)

  @doc "Adds a person."
  def create_participant(actor_id, attrs), do: insert(attrs, fn _participant -> actor_id end)

  @doc "Adds a person who joins the group themselves; they are the actor of the entry."
  def join(attrs), do: insert(attrs, & &1.id)

  defp insert(attrs, actor) do
    Repo.transact(fn ->
      with {:ok, participant} <- Repo.insert(Participant.changeset(%Participant{}, attrs)),
           {:ok, _activity} <-
             Activities.log_settings(
               actor.(participant),
               "Person „#{participant.name}“ hinzugefügt"
             ) do
        {:ok, participant}
      end
    end)
  end

  @doc "Renames a person; logged only when the name changes."
  def rename_participant(actor_id, %Participant{} = participant, attrs) do
    Repo.transact(fn ->
      with {:ok, renamed} <- Repo.update(Participant.changeset(participant, attrs)),
           {:ok, _activity} <- log_rename(actor_id, participant.name, renamed.name) do
        {:ok, renamed}
      end
    end)
  end

  defp log_rename(_actor_id, same, same), do: {:ok, nil}

  defp log_rename(actor_id, old, new),
    do: Activities.log_settings(actor_id, "Person „#{old}“ umbenannt in „#{new}“")

  @doc """
  Archives a person. Refused while their balance is not 0: they would vanish from the forms while
  money is still owed.
  """
  def archive_participant(actor_id, %Participant{} = participant) do
    Repo.transact(fn ->
      case Balances.balance(participant.id) do
        0 ->
          set_archived(actor_id, participant, DateTime.utc_now(), "archiviert")

        balance ->
          participant
          |> Changeset.change()
          |> Changeset.add_error(
            :archived_at,
            "#{participant.name} hat noch einen Saldo von #{Money.format_cents(balance)}. " <>
              "Bitte erst ausgleichen, dann archivieren."
          )
          |> Changeset.apply_action(:update)
      end
    end)
  end

  @doc "Brings an archived person back."
  def reactivate_participant(actor_id, %Participant{} = participant),
    do: Repo.transact(fn -> set_archived(actor_id, participant, nil, "reaktiviert") end)

  # Logged even when nothing changes.
  defp set_archived(actor_id, participant, archived_at, verb) do
    with {:ok, participant} <-
           participant |> Changeset.change(archived_at: archived_at) |> Repo.update(),
         {:ok, _activity} <-
           Activities.log_settings(actor_id, "Person „#{participant.name}“ #{verb}") do
      {:ok, participant}
    end
  end
end
