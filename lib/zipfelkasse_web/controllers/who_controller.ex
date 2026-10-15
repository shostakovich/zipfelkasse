defmodule ZipfelkasseWeb.WhoController do
  @moduledoc """
  "Wer bist du?": whoever can open the app picks who they are or adds themselves; there is no
  login. The choice goes into the session, then the visitor returns to where they came from.
  """
  use ZipfelkasseWeb, :controller

  alias Zipfelkasse.Participants
  alias Zipfelkasse.Participants.Participant
  alias ZipfelkasseWeb.{CurrentParticipant, Layouts, Params, ReturnPath}

  def show(conn, params) do
    page(conn, 200, ReturnPath.safe(params["return_to"]))
  end

  def choose(conn, params) do
    return_to = ReturnPath.safe(params["return_to"])

    case participant(params["id"]) do
      %Participant{archived_at: nil} = participant ->
        conn |> choose_participant(participant) |> redirect(to: return_to)

      _nobody ->
        page(conn, 422, return_to, error: "Diese Person gibt es nicht (mehr).")
    end
  end

  def create(conn, params) do
    return_to = ReturnPath.safe(params["return_to"])
    attrs = %{name: get_in(params, ["person", "name"]) || ""}

    case Participants.join(attrs) do
      {:ok, participant} ->
        conn
        |> choose_participant(participant)
        |> put_flash(:info, "Willkommen!")
        |> redirect(to: return_to)

      {:error, changeset} ->
        page(conn, 422, return_to, form: Phoenix.Component.to_form(changeset, as: :person))
    end
  end

  defp participant(id) do
    if id = Params.positive_integer(id), do: Participants.get_participant(id)
  end

  defp choose_participant(conn, participant),
    do: put_session(conn, :participant_id, participant.id)

  defp page(conn, status, return_to, opts \\ []) do
    form =
      Keyword.get_lazy(opts, :form, fn ->
        Phoenix.Component.to_form(Participants.change_participant(%Participant{}), as: :person)
      end)

    conn
    |> put_status(status)
    |> render(:show,
      page_title: Layouts.page_title("Wer bist du?"),
      current_participant: CurrentParticipant.from_session(get_session(conn)),
      participants: Participants.list_participants(),
      return_to: return_to,
      error: opts[:error],
      form: form
    )
  end
end
