defmodule ZipfelkasseWeb.CurrentParticipantTest do
  use ZipfelkasseWeb.ConnCase

  import Phoenix.LiveViewTest
  import Zipfelkasse.Fixtures

  alias Phoenix.LiveView.Socket
  alias Zipfelkasse.Participants
  alias ZipfelkasseWeb.CurrentParticipant

  defp mount(session), do: CurrentParticipant.on_mount(:default, %{}, session, %Socket{})

  test "the live session takes the person from the session" do
    {:ok, anna} = Participants.join(%{name: "Anna"})

    assert {:cont, socket} = mount(%{"participant_id" => anna.id})
    assert socket.assigns.current_participant.id == anna.id
  end

  test "the live session sends a person archived meanwhile, or nobody, to /who" do
    {:ok, anna} = Participants.join(%{name: "Anna"})
    {:ok, _anna} = Participants.archive_participant(nil, anna)

    for session <- [%{"participant_id" => anna.id}, %{"participant_id" => 999}, %{}] do
      assert {:halt, %Socket{redirected: {:redirect, %{to: "/who"}}}} = mount(session)
    end
  end

  test "a live page sends a person archived meanwhile to /who and back to the page",
       %{conn: conn} do
    h = household()
    expense = create!(equal(h, "Kino", 2000, "2026-09-01", h.ben, [h.ben, h.cleo]))
    conn = init_test_session(conn, participant_id: h.anna)
    anna = Participants.get_participant(h.anna)

    for {page, back} <- [
          {~p"/expenses/#{expense}", "/who?return_to=%2Fexpenses%2F#{expense.id}"},
          {~p"/expenses/new?#{[amount: "1250", to: h.ben]}",
           "/who?return_to=%2Fexpenses%2Fnew%3Famount%3D1250%26to%3D#{h.ben}"},
          {~p"/", "/who"}
        ] do
      {:ok, anna} = Participants.reactivate_participant(nil, anna)
      rendered = get(conn, page)
      {:ok, _anna} = Participants.archive_participant(nil, anna)

      assert {:error, {:redirect, %{to: ^back}}} = live(rendered)
    end
  end
end
