defmodule ZipfelkasseWeb.ParticipantsLive do
  @moduledoc """
  The people of the group with their number of expenses and balance: rename, archive (only with
  a balance of 0), bring back, add.
  """
  use ZipfelkasseWeb, :live_view

  alias Zipfelkasse.{Balances, Expenses, Participants}
  alias Zipfelkasse.Participants.Participant

  @impl true
  def mount(_params, _session, socket) do
    {:ok,
     socket
     |> assign(page_title: Layouts.page_title("Teilnehmer"), renaming: nil)
     |> assign_new_form(Participants.change_participant(%Participant{}))
     |> load()}
  end

  defp load(socket) do
    counts = Expenses.count_by_participant()
    balances = Balances.balances()

    {archived, active} =
      Participants.list_participants(:all)
      |> Enum.map(fn person ->
        %{
          person: person,
          expenses: Map.get(counts, person.id, 0),
          balance: Map.get(balances, person.id, 0)
        }
      end)
      |> Enum.split_with(&Participant.archived?(&1.person))

    assign(socket, active: active, archived: archived)
  end

  defp assign_new_form(socket, changeset),
    do: assign(socket, new_form: to_form(changeset, as: :person))

  defp assign_rename_form(socket, changeset),
    do: assign(socket, rename_form: to_form(changeset, as: :rename))

  @impl true
  def handle_event("validate_new", %{"person" => params}, socket) do
    changeset = Participants.change_participant(%Participant{}, params)
    {:noreply, assign_new_form(socket, Map.put(changeset, :action, :validate))}
  end

  def handle_event("create", %{"person" => params}, socket) do
    case Participants.create_participant(socket.assigns.current_participant.id, params) do
      {:ok, person} ->
        {:noreply,
         socket
         |> put_flash(:info, "„#{person.name}“ hinzugefügt.")
         |> assign_new_form(Participants.change_participant(%Participant{}))
         |> load()}

      {:error, changeset} ->
        {:noreply, assign_new_form(socket, changeset)}
    end
  end

  def handle_event("rename", %{"id" => id}, socket) do
    with_person(socket, id, fn person ->
      socket
      |> assign(renaming: person)
      |> assign_rename_form(Participants.change_participant(person))
    end)
  end

  def handle_event("cancel_rename", _params, socket),
    do: {:noreply, assign(socket, renaming: nil)}

  def handle_event("validate_rename", %{"rename" => params}, socket) do
    changeset = Participants.change_participant(socket.assigns.renaming, params)
    {:noreply, assign_rename_form(socket, Map.put(changeset, :action, :validate))}
  end

  def handle_event("save_rename", %{"rename" => params}, socket) do
    %{current_participant: me, renaming: person} = socket.assigns

    case Participants.rename_participant(me.id, person, params) do
      {:ok, renamed} ->
        me = if renamed.id == me.id, do: renamed, else: me

        {:noreply,
         socket
         |> put_flash(:info, "Gespeichert.")
         |> assign(renaming: nil, current_participant: me)
         |> load()}

      {:error, changeset} ->
        {:noreply, assign_rename_form(socket, changeset)}
    end
  end

  def handle_event("archive", %{"id" => id}, socket) do
    with_person(socket, id, fn person ->
      me = socket.assigns.current_participant.id

      case Participants.archive_participant(me, person) do
        {:ok, %Participant{id: ^me} = archived} ->
          socket |> put_flash(:info, "„#{archived.name}“ archiviert.") |> redirect(to: ~p"/who")

        {:ok, archived} ->
          socket |> put_flash(:info, "„#{archived.name}“ archiviert.") |> load()

        {:error, changeset} ->
          {message, _opts} = changeset.errors[:archived_at]
          put_flash(socket, :error, message)
      end
    end)
  end

  def handle_event("reactivate", %{"id" => id}, socket) do
    with_person(socket, id, fn person ->
      {:ok, person} =
        Participants.reactivate_participant(socket.assigns.current_participant.id, person)

      socket |> put_flash(:info, "„#{person.name}“ reaktiviert.") |> load()
    end)
  end

  defp with_person(socket, id, fun) do
    case Participants.get_participant(id) do
      %Participant{} = person -> {:noreply, fun.(person)}
      nil -> {:noreply, socket |> put_flash(:error, "Person nicht gefunden.") |> load()}
    end
  end

  @impl true
  def render(assigns) do
    ~H"""
    <Layouts.app flash={@flash} current={:settings} participant={@current_participant}>
      <.header back={~p"/settings"} back_label="Einstellungen">
        Teilnehmer
        <:subtitle>
          Personen umbenennen oder archivieren. Archivierte Personen stehen bei neuen Ausgaben nicht mehr zur Wahl; ihre alten Ausgaben bleiben erhalten.
        </:subtitle>
      </.header>

      <div class="flex flex-col gap-8">
        <.list id="participants">
          <.list_row
            :for={row <- @active}
            id={"person-#{row.person.id}"}
            title={row.person.name}
          >
            <:leading>
              <.avatar
                initials={initial(row.person.name)}
                shape={:round}
                tone={if row.person.id == @current_participant.id, do: :primary, else: :base}
              />
            </:leading>
            <.badge
              :if={row.person.id == @current_participant.id}
              style={:plain}
              class="ms-1.5 align-text-bottom"
            >
              das bist du
            </.badge>
            <:meta>
              {expense_count(row.expenses)}<.meta_sep />Saldo
              <.amount value={row.balance} signed tone={:negative} />
            </:meta>
            <:action
              id={"person-#{row.person.id}-rename"}
              label="Umbenennen"
              icon="pencil"
              on_click={JS.push("rename", value: %{id: row.person.id})}
            />
            <:action
              id={"person-#{row.person.id}-archive"}
              label="Archivieren"
              icon="archive"
              on_click={JS.push("archive", value: %{id: row.person.id})}
            />
          </.list_row>
        </.list>

        <section aria-labelledby="participants-new">
          <.section_heading id="participants-new">Person hinzufügen</.section_heading>
          <.form for={@new_form} id="participant-form" phx-change="validate_new" phx-submit="create">
            <.input
              field={@new_form[:name]}
              label="Name"
              placeholder="Name"
              required
              maxlength={Zipfelkasse.Names.max_length()}
              autocomplete="off"
              phx-patch-focused
              inline
            >
              <.button type="submit" variant={:primary} icon="plus" class="join-item">
                Hinzufügen
              </.button>
            </.input>
          </.form>
        </section>

        <section :if={@archived != []} aria-labelledby="participants-archived">
          <.section_heading id="participants-archived" count={length(@archived)}>
            Archiviert
          </.section_heading>
          <.list id="participants-archived-list">
            <.list_row
              :for={row <- @archived}
              id={"person-#{row.person.id}"}
              title={row.person.name}
            >
              <:meta>{expense_count(row.expenses)}</:meta>
              <:trailing>
                <.button
                  id={"person-#{row.person.id}-reactivate"}
                  size={:sm}
                  icon="undo-2"
                  phx-click={JS.push("reactivate", value: %{id: row.person.id})}
                >
                  Zurückholen
                </.button>
              </:trailing>
            </.list_row>
          </.list>
        </section>
      </div>

      <.rename_popover
        :if={@renaming}
        id={"rename-#{@renaming.id}"}
        name={@renaming.name}
        anchor={"person-#{@renaming.id}"}
        form={@rename_form}
      />
    </Layouts.app>
    """
  end

  defp initial(name), do: name |> String.first() |> String.upcase()
end
