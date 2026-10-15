defmodule ZipfelkasseWeb.RatesLive do
  @moduledoc """
  Exchange rates: the manual ones (add, delete), what the ECB cache holds with the newest day's
  rates and a refresh, and the rates of the newest expenses in another currency. The refresh
  downloads from the ECB, so it runs in the background.
  """
  use ZipfelkasseWeb, :live_view

  alias Zipfelkasse.{Dates, Fx, LocalTime, Money}

  @impl true
  def mount(_params, _session, socket) do
    {:ok,
     socket
     |> assign(page_title: Layouts.page_title("Wechselkurse"), refreshing: false)
     |> assign_form(blank_params(), [])
     |> load()}
  end

  defp load(socket) do
    assign(socket,
      manual: Fx.list_manual_rates(),
      stats: Fx.ecb_stats(),
      latest: Fx.latest_ecb_rates(),
      used: Fx.recent_expense_rates(10),
      currencies: Fx.list_currencies()
    )
  end

  defp blank_params,
    do: %{"currency" => "", "date" => Date.to_iso8601(LocalTime.today()), "rate" => ""}

  defp assign_form(socket, params, errors),
    do: assign(socket, form: to_form(params, as: :rate, errors: errors))

  defp typed(params), do: Map.merge(blank_params(), Map.take(params, ~w(currency date rate)))

  # Kept on the server, so that a re-render or reconnect leaves the fields as typed.
  @impl true
  def handle_event("change", %{"rate" => params}, socket),
    do: {:noreply, assign_form(socket, typed(params), socket.assigns.form.errors)}

  def handle_event("save", %{"rate" => params}, socket) do
    params = typed(params)

    with {:ok, attrs} <- read(params),
         {:ok, rate} <- Fx.put_manual_rate(socket.assigns.current_participant.id, attrs) do
      {:noreply,
       socket
       |> put_flash(:info, "Kurs für #{rate.currency} gespeichert.")
       |> assign_form(blank_params(), [])
       |> load()}
    else
      {:error, %Ecto.Changeset{errors: errors}} -> {:noreply, assign_form(socket, params, errors)}
      {:error, errors} -> {:noreply, assign_form(socket, params, errors)}
    end
  end

  def handle_event("delete", %{"currency" => currency, "date" => date}, socket) do
    me = socket.assigns.current_participant.id

    with {:ok, date} <- Date.from_iso8601(date),
         {:ok, _activity} <- Fx.delete_manual_rate(me, currency, date) do
      {:noreply, socket |> put_flash(:info, "Manueller Kurs für #{currency} gelöscht.") |> load()}
    else
      _missing ->
        {:noreply,
         socket |> put_flash(:error, "Diesen manuellen Kurs gibt es nicht (mehr).") |> load()}
    end
  end

  def handle_event("refresh", _params, socket) do
    {:noreply,
     socket |> assign(refreshing: true) |> start_async(:refresh, fn -> Fx.refresh() end)}
  end

  @impl true
  def handle_async(:refresh, result, socket) do
    socket = assign(socket, refreshing: false)

    case result do
      {:ok, {:ok, day}} ->
        {:noreply,
         socket
         |> put_flash(:info, "EZB-Kurse aktualisiert (Stand #{Format.date(day)}).")
         |> load()}

      {:ok, {:error, message}} ->
        {:noreply, put_flash(socket, :error, message)}

      {:exit, _reason} ->
        {:noreply, put_flash(socket, :error, Fx.unavailable_message("Abbruch"))}
    end
  end

  # Date and rate are typed text; the changeset checks what they read as.
  defp read(params) do
    date = Dates.parse(params["date"])
    rate = rate(params["rate"])
    attrs = %{currency: params["currency"], date: parsed(date), rate: parsed(rate)}

    unread =
      for {field, {:error, message}} <- [date: date, rate: rate], do: {field, {message, []}}

    checked = Fx.change_manual_rate(attrs).errors
    errors = unread ++ Keyword.drop(checked, Keyword.keys(unread))

    if errors == [], do: {:ok, attrs}, else: {:error, errors}
  end

  defp parsed({:ok, value}), do: value
  defp parsed({:error, _message}), do: nil

  defp rate(text) do
    if String.trim(text) == "", do: {:ok, nil}, else: Money.parse_rate(text)
  end

  defp source_label(:ecb), do: "EZB"
  defp source_label(:manual), do: "manuell"
  defp source_label(_source), do: "fest"

  @impl true
  def render(assigns) do
    ~H"""
    <Layouts.app flash={@flash} current={:settings} participant={@current_participant}>
      <.header back={~p"/settings"} back_label="Einstellungen">
        Wechselkurse
        <:subtitle>
          Kurse gelten wie bei der EZB als Einheiten der Fremdwährung pro 1 €. Für ein Ausgabedatum gilt der jüngste manuelle Kurs mit „gültig ab“ am oder vor diesem Datum – er hat Vorrang vor dem EZB-Kurs, bis ein neuerer manueller Kurs eingetragen oder er gelöscht wird. Ohne manuellen Kurs gilt der EZB-Referenzkurs vom Ausgabedatum bzw. vom letzten Bankarbeitstag davor.
        </:subtitle>
      </.header>

      <div class="flex flex-col gap-8">
        <section aria-labelledby="rates-manual">
          <.section_heading id="rates-manual">Manuelle Kurse</.section_heading>
          <p class="mb-3 text-sm text-base-content/70">
            Zum Beispiel für den echten Kartenkurs oder für Währungen, die die EZB nicht führt.
          </p>
          <.table
            :if={@manual != []}
            id="manual-rates"
            rows={@manual}
            row_id={&"manual-#{&1.currency}-#{&1.date}"}
          >
            <:col :let={rate} label="Währung">{rate.currency}</:col>
            <:col :let={rate} label="Gültig ab" align={:end}>{Format.date(rate.date)}</:col>
            <:col :let={rate} label="1 € =" align={:end}>
              {Money.format_rate(rate.rate)} {rate.currency}
            </:col>
            <:col :let={rate} class="w-12">
              <.button
                id={"manual-#{rate.currency}-#{rate.date}-delete"}
                variant={:ghost}
                size={:sm}
                icon="trash-2"
                icon_only
                label={"Kurs für #{rate.currency} ab #{Format.date(rate.date)} löschen"}
                confirm={"Manuellen Kurs für #{rate.currency} ab #{Format.date(rate.date)} löschen?"}
                confirm_text="Ausgaben, die ihn schon nutzen, behalten ihren Kurs."
                phx-click={
                  JS.push("delete",
                    value: %{currency: rate.currency, date: Date.to_iso8601(rate.date)}
                  )
                }
              />
            </:col>
          </.table>
          <p :if={@manual == []} class="text-sm">Noch keine manuellen Kurse.</p>

          <.form
            for={@form}
            id="rate-form"
            phx-change="change"
            phx-submit="save"
            phx-hook="Setzkasten.Components.Forms.FocusInvalid"
            class="mt-4"
          >
            <div class="grid gap-x-4 sm:grid-cols-[minmax(0,1fr)_minmax(0,1fr)_minmax(0,1.5fr)]">
              <.input
                field={@form[:currency]}
                label="Währung"
                required
                maxlength="3"
                placeholder="USD"
                autocomplete="off"
                autocapitalize="characters"
                list="rate-currencies"
                phx-patch-focused
              />
              <.input field={@form[:date]} type="date" label="Gültig ab" required phx-patch-focused />
              <.input
                field={@form[:rate]}
                label="Kurs (1 € = …)"
                required
                numeric
                placeholder="1,0850"
                autocomplete="off"
                phx-patch-focused
                help="Für 1 € gibt es 1,08 US-Dollar → 1,08."
              />
            </div>
            <datalist id="rate-currencies">
              <option :for={currency <- @currencies} value={currency}></option>
            </datalist>
            <.action_bar>
              <.button
                id="rate-submit"
                type="submit"
                variant={:primary}
                icon="save"
                phx-disable-with="Speichert …"
              >
                Kurs speichern
              </.button>
            </.action_bar>
          </.form>
        </section>

        <section aria-labelledby="rates-ecb">
          <.section_heading id="rates-ecb">EZB-Referenzkurse</.section_heading>
          <p id="rates-stats" class="max-w-prose text-sm text-base-content/70">
            <%= if @stats.count > 0 do %>
              Zwischengespeichert: {@stats.count} Kurse für {@stats.currencies} Währungen vom {Format.date(
                @stats.from
              )} bis {Format.date(@stats.to)}.
            <% else %>
              Noch keine EZB-Kurse zwischengespeichert – sie werden bei Bedarf automatisch geladen.
            <% end %>
            Neue Kurse werden täglich um 17 Uhr automatisch abgerufen.
          </p>
          <.button
            id="rates-refresh"
            icon="refresh-cw"
            loading={@refreshing}
            phx-click="refresh"
            class="mt-3 mb-4"
          >
            EZB-Kurse jetzt aktualisieren
          </.button>
          <.table
            :if={@latest != []}
            id="ecb-rates"
            rows={@latest}
            row_id={&"ecb-#{&1.currency}"}
            size={:sm}
          >
            <:col :let={rate} label="Währung">{rate.currency}</:col>
            <:col :let={rate} label="Stand" align={:end} show_from={:sm}>
              {Format.date(rate.date)}
            </:col>
            <:col :let={rate} label="1 € =" align={:end}>
              {Money.format_rate(rate.rate)} {rate.currency}
            </:col>
          </.table>
        </section>

        <section :if={@used != []} aria-labelledby="rates-used">
          <.section_heading id="rates-used">Zuletzt verwendet</.section_heading>
          <p class="mb-3 text-sm text-base-content/70">
            Kurse der jüngsten Ausgaben in Fremdwährung.
          </p>
          <.table
            id="used-rates"
            rows={@used}
            row_id={&"used-#{&1.expense_id}"}
            row_link={&~p"/expenses/#{&1.expense_id}"}
          >
            <:col :let={used} label="Ausgabe">
              {used.title}
              <.cell_sub hide_from={:sm}>
                {join_meta([Format.date(used.date), source_label(used.source)])}
              </.cell_sub>
            </:col>
            <:col :let={used} label="Datum" align={:end} show_from={:sm}>
              {Format.date(used.date)}
            </:col>
            <:col :let={used} label="1 € =" align={:end}>
              {Money.format_rate(used.rate)} {used.currency}
            </:col>
            <:col :let={used} label="Quelle" show_from={:sm}>{source_label(used.source)}</:col>
          </.table>
        </section>
      </div>
    </Layouts.app>
    """
  end
end
