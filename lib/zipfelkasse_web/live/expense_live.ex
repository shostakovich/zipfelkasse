defmodule ZipfelkasseWeb.ExpenseLive do
  @moduledoc """
  The form of an expense or reimbursement: new (`:new`, prefilled for a suggested reimbursement)
  or saved (`:edit`, read-only once deleted, with its history). Every change goes through
  `Zipfelkasse.Expenses.Form`, which keeps the text as typed and fills in what an edit implies;
  the split shows live, and a foreign rate is looked up in the background.

  Errors of a submit stay on the fields until they change.
  """
  use ZipfelkasseWeb, :live_view

  alias Ecto.Changeset
  alias Phoenix.HTML.FormData
  alias Zipfelkasse.{Activities, Categories, Expenses, LocalTime, Participants, Split}
  alias Zipfelkasse.Expenses.{Expense, Form}
  alias ZipfelkasseWeb.Params

  @impl true
  def mount(params, _session, socket) do
    socket =
      assign(socket,
        suggestions: Expenses.category_suggestions(),
        people: Participants.list_participants(:all),
        categories: Categories.list_categories(:all),
        errors: [],
        submitted: nil,
        rate_loading: false
      )

    {:ok, socket |> start(socket.assigns.live_action, params) |> assign_form()}
  end

  defp start(socket, :new, params) do
    known = MapSet.new(socket.assigns.people, & &1.id)

    person = fn key ->
      with id when is_integer(id) <- Params.positive_integer(params[key]),
           true <- id in known,
           do: id
    end

    data =
      Expenses.new_form(
        today: LocalTime.today(),
        participant_id: socket.assigns.current_participant.id,
        reimbursement: params["reimbursement"] in ["1", "true"],
        from: person.("from"),
        to: person.("to"),
        amount_cents: Params.positive_integer(params["amount"])
      )

    assign(socket,
      page_title: Layouts.page_title("Neue Ausgabe"),
      expense: nil,
      deleted?: false,
      data: data,
      history: []
    )
  end

  defp start(socket, :edit, %{"id" => id}) do
    with id when is_integer(id) <- Params.positive_integer(id),
         %Expense{} = expense <- Expenses.get_expense(id) do
      assign(socket,
        page_title: Layouts.page_title(expense.title),
        expense: expense,
        deleted?: Expense.deleted?(expense),
        data: Expenses.edit_form(expense),
        history: Activities.list_activities(expense_id: expense.id)
      )
    else
      _missing -> raise ZipfelkasseWeb.NotFoundError, "Ausgabe nicht gefunden."
    end
  end

  @impl true
  def handle_event("change", %{"expense" => params}, socket) do
    changeset = changeset(socket, params)

    {:noreply,
     socket
     |> assign(data: Changeset.apply_changes(changeset))
     |> keep_errors()
     |> then(&if(Form.rate_lookup?(changeset), do: lookup_rate(&1), else: &1))
     |> assign_form()}
  end

  def handle_event("recover", %{"expense" => params}, socket) do
    data = socket.assigns.data |> Form.restore(params) |> Changeset.apply_changes()
    {:noreply, socket |> assign(data: data) |> assign_form()}
  end

  def handle_event("select_all", _params, socket) do
    data = socket.assigns.data |> Form.select_all() |> Changeset.apply_changes()
    {:noreply, socket |> assign(data: data) |> keep_errors() |> assign_form()}
  end

  def handle_event("load_rate", _params, socket),
    do: {:noreply, socket |> lookup_rate() |> assign_form()}

  def handle_event("save", %{"expense" => params}, socket) do
    data = socket |> changeset(params) |> Changeset.apply_changes()
    %{current_participant: me, expense: expense} = socket.assigns

    case Expenses.save_form(me.id, data, expense) do
      {:ok, saved} ->
        kind = if saved.reimbursement, do: "Rückzahlung", else: "Ausgabe"
        verb = if expense, do: "gespeichert", else: "angelegt"

        {:noreply,
         socket
         |> put_flash(:info, "#{kind} „#{saved.title}“ #{verb}.")
         |> push_navigate(to: ~p"/")}

      {:error, %Changeset{} = changeset} ->
        data = Changeset.apply_changes(changeset)

        {:noreply,
         socket
         |> assign(data: data, errors: changeset.errors, submitted: data)
         |> assign_form()}

      {:error, :deleted} ->
        {:noreply,
         socket
         |> put_flash(
           :error,
           "Diese Ausgabe wurde gelöscht und kann nicht mehr bearbeitet werden."
         )
         |> push_navigate(to: ~p"/expenses/#{expense}")}

      {:error, :not_found} ->
        {:noreply,
         socket |> put_flash(:error, "Ausgabe nicht gefunden.") |> push_navigate(to: ~p"/")}
    end
  end

  def handle_event("delete", _params, socket) do
    %{current_participant: me, expense: expense} = socket.assigns

    case Expenses.delete_expense(me.id, expense) do
      {:ok, deleted} ->
        {:noreply,
         socket |> put_flash(:info, "„#{deleted.title}“ gelöscht.") |> push_navigate(to: ~p"/")}

      {:error, :not_found} ->
        {:noreply,
         socket
         |> put_flash(:error, "Ausgabe nicht gefunden oder schon gelöscht.")
         |> push_navigate(to: ~p"/")}
    end
  end

  defp changeset(socket, params),
    do: Form.changeset(socket.assigns.data, params, suggestions: socket.assigns.suggestions)

  # The ECB file may take seconds to download; the form stays usable meanwhile.
  defp lookup_rate(socket) do
    data = socket.assigns.data
    asked = {Form.currency_code(data), data.date, data.rate}

    socket
    |> assign(rate_loading: true)
    |> start_async(:rate, fn -> {asked, Expenses.lookup_form_rate(data)} end)
  end

  @impl true
  def handle_async(:rate, {:ok, {asked, %Changeset{changes: changes}}}, socket) do
    data = socket.assigns.data
    socket = assign(socket, rate_loading: false)

    if asked == {Form.currency_code(data), data.date, data.rate} do
      data = data |> Changeset.change(changes) |> Changeset.apply_changes()
      {:noreply, socket |> assign(data: data) |> assign_form()}
    else
      {:noreply, assign_form(socket)}
    end
  end

  def handle_async(:rate, {:exit, _reason}, socket) do
    data = %{
      socket.assigns.data
      | rate_hint: "Kurs konnte nicht geladen werden. Kurs bitte von Hand eintragen."
    }

    {:noreply, socket |> assign(data: data, rate_loading: false) |> assign_form()}
  end

  defp keep_errors(%{assigns: %{errors: []}} = socket), do: socket

  defp keep_errors(socket) do
    %{errors: errors, submitted: submitted, data: data} = socket.assigns

    assign(socket,
      errors:
        Enum.filter(errors, fn {field, _} -> watched(submitted, field) == watched(data, field) end)
    )
  end

  defp watched(form, :currency), do: Form.currency_code(form)
  defp watched(form, :amount), do: {form.amount, Form.currency_code(form)}

  defp watched(form, :rows),
    do: {form.rows, form.split_mode, form.reimbursement, form.amount, Form.currency_code(form)}

  defp watched(form, field), do: Map.get(form, field)

  defp assign_form(socket) do
    %{data: data, errors: errors} = socket.assigns

    changeset = %{
      Changeset.change(data)
      | params: params(data),
        errors: errors,
        action: if(errors != [], do: :validate)
    }

    form = to_form(changeset, as: :expense)
    code = Form.currency_code(data)
    unit = if code in ["", "EUR"], do: "€", else: code

    assign(socket,
      form: form,
      rows: FormData.to_form(changeset, form, :rows, []),
      preview: Expenses.preview_form(data),
      foreign?: code not in ["", "EUR"],
      unit: unit,
      unit_label: unit_label(data, unit),
      weights?: not data.reimbursement and data.split_mode != :equal,
      all_selected?: Enum.all?(data.rows, & &1.selected)
    )
  end

  # The form's values as params, so that errors count as entered and every field shows `data`.
  defp params(data) do
    fields =
      ~w(title date category_id paid_by_id currency currency_other amount rate notes reimbursement split_mode)a

    rows =
      for {row, index} <- Enum.with_index(data.rows), into: %{} do
        {"#{index}",
         %{
           "participant_id" => row.participant_id,
           "selected" => row.selected,
           "weight" => row.weight
         }}
      end

    fields |> Map.new(&{Atom.to_string(&1), Map.fetch!(data, &1)}) |> Map.put("rows", rows)
  end

  @impl true
  def render(assigns) do
    ~H"""
    <Layouts.app flash={@flash} current={:expenses} participant={@current_participant} fab={false}>
      <.header back={~p"/"} back_label="Ausgaben">
        {heading(@expense, @deleted?)}
        <:subtitle :if={@expense}>{created(@expense)}</:subtitle>
        <:badge :if={@expense && @expense.recurring_expense_id}>
          <.badge icon="repeat">Wiederkehrend</.badge>
        </:badge>
      </.header>

      <.alert :if={@deleted?} tone={:warning} class="mb-6">
        Diese Ausgabe wurde am {Format.datetime(LocalTime.from_utc(@expense.deleted_at))} gelöscht
        und zählt nicht mehr zu den Salden.
      </.alert>

      <.form
        for={@form}
        id="expense-form"
        phx-change="change"
        phx-submit="save"
        phx-auto-recover="recover"
        phx-hook="Setzkasten.Components.Forms.FocusInvalid"
        novalidate
      >
        <.alert :if={@errors != []} tone={:error} title={error_title(@errors)} class="mb-4">
          Bitte prüfe die markierten Felder.
        </.alert>
        <fieldset disabled={@deleted?} class="min-w-0">
          <div class="grid gap-x-4 md:grid-cols-2">
            <.input
              field={@form[:title]}
              label="Titel"
              required
              maxlength="200"
              placeholder="z. B. Einkauf Wochenmarkt"
              autocomplete="off"
              enterkeyhint="next"
            />
            <.input field={@form[:date]} type="date" label="Datum" required />
            <.input
              field={@form[:category_id]}
              type="select"
              label="Kategorie"
              prompt="Keine Kategorie"
              options={category_options(@categories, @data.category_id)}
              help={@data.category_suggested && "Vorschlag anhand früherer Ausgaben"}
            />
            <.input
              field={@form[:paid_by_id]}
              type="select"
              label={if @data.reimbursement, do: "Zurückgezahlt von", else: "Bezahlt von"}
              options={payer_options(@people, @data.paid_by_id)}
              required
            />
            <div>
              <.input
                field={@form[:currency]}
                type="select"
                label="Währung"
                options={currency_options()}
              />
              <.input
                :if={@data.currency == ""}
                field={@form[:currency_other]}
                label="Andere Währung (ISO-Code)"
                hide_label
                maxlength="3"
                placeholder="ISO-Code, z. B. THB"
                autocapitalize="characters"
                autocomplete="off"
                class="mt-2"
              />
            </div>
            <.input
              field={@form[:amount]}
              label="Betrag"
              suffix={@unit}
              numeric
              required
              placeholder="0,00"
              autocomplete="off"
            />
            <%= if @foreign? do %>
              <div>
                <input type="hidden" name={@form[:rate_source].name} value={@data.rate_source} />
                <.input
                  field={@form[:rate]}
                  label="Wechselkurs"
                  prefix="1 € ="
                  suffix={@unit}
                  numeric
                  placeholder="automatisch"
                  autocomplete="off"
                  help={rate_hint(@data, @rate_loading)}
                />
                <.button
                  :if={@data.rate_source != :ecb}
                  id="expense-load-rate"
                  variant={:ghost}
                  size={:sm}
                  icon="refresh-cw"
                  loading={@rate_loading}
                  phx-click="load_rate"
                  class="-ms-3"
                >
                  EZB-Kurs laden
                </.button>
              </div>
              <.description_list class="pt-2 md:pt-9">
                <:item label="Umgerechnet in Euro">
                  <span id="expense-eur" class="font-semibold">
                    <.amount :if={@preview.eur_cents} value={@preview.eur_cents} />
                    <span :if={!@preview.eur_cents}>–</span>
                  </span>
                </:item>
              </.description_list>
            <% end %>
            <div class="md:col-span-2">
              <.input
                field={@form[:reimbursement]}
                type="checkbox"
                label="Das ist eine Rückzahlung"
              />
            </div>
            <div class="md:col-span-2">
              <.input
                field={@form[:notes]}
                type="textarea"
                label="Notiz"
                rows="2"
                maxlength="2000"
              />
            </div>
          </div>

          <fieldset
            id="expense-split"
            class="mt-8 min-w-0"
            aria-labelledby="expense-split-heading"
            aria-describedby={split_describedby(@form)}
            aria-invalid={@form[:rows].errors != [] && "true"}
          >
            <.section_heading id="expense-split-heading">
              {if @data.reimbursement, do: "An wen?", else: "Für wen?"}
              <:actions :if={!@data.reimbursement}>
                <.button id="expense-select-all" variant={:ghost} size={:sm} phx-click="select_all">
                  {if @all_selected?, do: "Keine auswählen", else: "Alle auswählen"}
                </.button>
              </:actions>
            </.section_heading>
            <p class="mb-3 text-sm text-base-content/70">
              {if @data.reimbursement,
                do: "Wähle genau eine Person, die das Geld bekommen hat.",
                else: "Wähle, für wen bezahlt wurde."}
            </p>
            <.table
              id="expense-rows"
              rows={@rows}
              row_id={&"split-row-#{&1[:participant_id].value}"}
              size={:dense}
            >
              <:col :let={row} label="Person">
                <input
                  type="hidden"
                  name={row[:participant_id].name}
                  value={row[:participant_id].value}
                />
                <.input
                  field={row[:selected]}
                  type="checkbox"
                  bare
                  label={archived_label(row[:name].value, row[:archived].value)}
                />
              </:col>
              <:col :let={row} :if={@weights?} label={@unit_label} align={:end}>
                <.input
                  field={row[:weight]}
                  label={"Wert für #{row[:name].value}"}
                  hide_label
                  numeric
                  autocomplete="off"
                  class="ms-auto w-28"
                />
              </:col>
              <:col :let={row} label="Anteil" align={:end}>
                <.amount
                  :if={cents = row[:selected].value && @preview.shares[row[:participant_id].value]}
                  value={cents}
                  class="text-base-content/70"
                />
              </:col>
            </.table>
            <.field_error id="expense-rows" field={@form[:rows]} />
            <p
              :if={!@data.reimbursement}
              id="expense-split-sum"
              class={["mt-3 text-sm", sum_tone(@preview.sum)]}
              aria-live="polite"
            >
              {sum_text(@preview.sum)}
            </p>
            <.disclosure
              :if={!@data.reimbursement}
              id="expense-split-more"
              variant={:button}
              summary="Weitere Aufteilungsoptionen …"
              open={@data.split_mode != :equal}
              class="mt-4"
            >
              <.input
                field={@form[:split_mode]}
                type="select"
                label="Aufteilung"
                options={Enum.map(Split.modes(), &{Split.label(&1), &1})}
                help={split_help(@unit)}
              />
            </.disclosure>
          </fieldset>
        </fieldset>

        <.action_bar :if={!@deleted?} sticky>
          <:secondary :if={@expense}>
            <.button
              id="expense-delete"
              variant={:danger_outline}
              icon="trash-2"
              confirm="Diese Ausgabe wirklich löschen?"
              confirm_text="Sie verschwindet aus Liste und Salden; im Aktivitätsprotokoll bleibt sie sichtbar."
              phx-click="delete"
            >
              Löschen
            </.button>
          </:secondary>
          <.button navigate={~p"/"}>Abbrechen</.button>
          <.button
            id="expense-submit"
            type="submit"
            variant={:primary}
            icon="save"
            phx-disable-with="Speichert …"
          >
            {if @expense, do: "Speichern", else: "Anlegen"}
          </.button>
        </.action_bar>
      </.form>

      <section :if={@expense} aria-labelledby="expense-history" class="mt-8">
        <.section_heading id="expense-history">Verlauf</.section_heading>
        <p :if={!@deleted? && @expense.recurring_expense_id} class="mb-2 text-sm">
          Diese Ausgabe wird automatisch wiederholt.
          <.link navigate={~p"/settings/recurring"} class="link link-primary">
            Wiederkehrende Ausgaben verwalten
          </.link>
        </p>
        <div :if={!@deleted? && !@expense.recurring_expense_id} class="mb-2">
          <.button
            navigate={~p"/settings/recurring/new?#{[expense_id: @expense.id]}"}
            variant={:ghost}
            size={:sm}
            icon="repeat"
            class="-ms-3"
          >
            Als wiederkehrend einrichten
          </.button>
        </div>
        <.list :if={@history != []} id="expense-activities">
          <.activity_entry
            :for={activity <- @history}
            id={"activity-#{activity.id}"}
            activity={activity}
          />
        </.list>
        <.empty_state :if={@history == []} title="Noch keine Einträge." />
      </section>
    </Layouts.app>
    """
  end

  defp heading(nil, _deleted?), do: "Ausgabe hinzufügen"
  defp heading(_expense, true), do: "Gelöschte Ausgabe"
  defp heading(_expense, false), do: "Ausgabe bearbeiten"

  defp created(expense) do
    created = "Angelegt am " <> local(expense.inserted_at)

    if expense.updated_at == expense.inserted_at,
      do: created,
      else: join_meta([created, "geändert am " <> local(expense.updated_at)])
  end

  defp local(utc), do: utc |> LocalTime.from_utc() |> Format.datetime()

  defp error_title([_one]), do: "1 Feld ist noch nicht richtig"
  defp error_title(errors), do: "#{length(errors)} Felder sind noch nicht richtig"

  defp category_options(categories, current) do
    for category <- categories, is_nil(category.archived_at) or category.id == current do
      {archived_label(category.name, not is_nil(category.archived_at)), category.id}
    end
  end

  defp payer_options(people, current) do
    for person <- people, is_nil(person.archived_at) or person.id == current do
      {archived_label(person.name, not is_nil(person.archived_at)), person.id}
    end
  end

  defp archived_label(name, true), do: "#{name} (archiviert)"
  defp archived_label(name, _active), do: name

  defp currency_options do
    common = for code <- Form.common_currencies(), do: {currency_label(code), code}
    common ++ [{"Andere …", ""}]
  end

  defp currency_label("EUR"), do: "EUR – Euro"
  defp currency_label(code), do: code

  defp rate_hint(_data, true), do: "Kurs wird geladen …"
  defp rate_hint(%Form{rate_hint: hint}, _loading) when is_binary(hint), do: hint
  defp rate_hint(%Form{rate_source: :manual}, _loading), do: "Von Hand eingetragener Kurs."
  defp rate_hint(%Form{rate_source: :ecb}, _loading), do: "EZB-Kurs."
  defp rate_hint(_data, _loading), do: "Leer lassen für den EZB-Kurs."

  defp sum_text({_ok_or_error, text}), do: text
  defp sum_text(nil), do: nil

  defp sum_tone({:error, _text}), do: "text-error-ink"
  defp sum_tone(_sum), do: nil

  defp split_describedby(form) do
    if form[:rows].errors != [] and Phoenix.Component.used_input?(form[:rows]),
      do: "expense-rows-error-0"
  end

  defp split_help("€"),
    do:
      "Nach Anteilen: z. B. 2 : 1. Nach Prozent: zusammen 100 %. Nach Beträgen: zusammen der Gesamtbetrag."

  defp split_help(code),
    do:
      "Nach Anteilen: z. B. 2 : 1. Nach Prozent: zusammen 100 %. Nach Beträgen: zusammen der Gesamtbetrag in #{code}."

  defp unit_label(%Form{split_mode: :shares}, _unit), do: "Anteile"
  defp unit_label(%Form{split_mode: :percent}, _unit), do: "%"
  defp unit_label(_data, unit), do: unit
end
