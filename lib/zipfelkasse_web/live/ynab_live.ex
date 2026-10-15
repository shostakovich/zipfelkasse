defmodule ZipfelkasseWeb.YnabLive do
  @moduledoc """
  The reader's YNAB connection: how it works, the token, plan, account and start date, the
  category mapping and the state of the sync. Asking YNAB may take seconds, so the page loads
  its lists and runs every change in the background; `?refresh=1` bypasses YNAB's cached lists.
  """
  use ZipfelkasseWeb, :live_view

  alias Zipfelkasse.Ynab

  @impl true
  def mount(_params, _session, socket) do
    {:ok,
     assign(socket,
       page_title: Layouts.page_title("YNAB"),
       overview: nil,
       failed: false,
       busy: nil,
       token_form: token_form(),
       saved_tokens: 0
     )}
  end

  @impl true
  def handle_params(params, _uri, socket),
    do: {:noreply, load(socket, refresh: params["refresh"] == "1")}

  defp load(socket, opts \\ []) do
    id = socket.assigns.current_participant.id

    socket
    |> assign(failed: false)
    |> start_async(:overview, fn -> Ynab.overview(id, opts) end)
  end

  defp token_form, do: to_form(%{"token" => ""}, as: :connection)

  # A new id replaces the field, which LiveView would leave as typed.
  defp clear_token(socket),
    do: assign(socket, token_form: token_form(), saved_tokens: socket.assigns.saved_tokens + 1)

  @impl true
  def handle_event("save_token", %{"connection" => %{"token" => token}}, socket),
    do: {:noreply, run(socket, :token, &Ynab.save_token(&1, token))}

  def handle_event("disconnect", _params, socket),
    do: {:noreply, run(socket, :disconnect, &Ynab.disconnect/1)}

  def handle_event("choose_target", %{"target" => params}, socket) do
    target = params["account"] || ""
    start = params["start"] || ""
    {:noreply, run(socket, :target, &Ynab.choose_target(&1, target, start))}
  end

  def handle_event("map_categories", params, socket) do
    mapping = Map.get(params, "mapping", %{})
    {:noreply, run(socket, :mapping, &Ynab.map_categories(&1, mapping))}
  end

  def handle_event("sync_now", _params, socket),
    do: {:noreply, run(socket, :sync, &Ynab.sync_now/1)}

  defp run(%{assigns: %{busy: nil}} = socket, action, fun) do
    id = socket.assigns.current_participant.id

    socket
    |> assign(busy: action)
    |> start_async(:action, fn -> {action, fun.(id)} end)
  end

  defp run(socket, _action, _fun), do: socket

  @impl true
  def handle_async(:overview, {:ok, overview}, socket), do: {:noreply, show(socket, overview)}

  def handle_async(:overview, {:exit, _reason}, socket),
    do: {:noreply, assign(socket, failed: true)}

  def handle_async(:action, {:ok, {action, result}}, socket) do
    socket = assign(socket, busy: nil)

    case result do
      {:ok, message} ->
        socket = socket |> put_flash(:info, message) |> load()

        {:noreply, if(action == :token, do: clear_token(socket), else: socket)}

      {:error, message} ->
        {:noreply, put_flash(socket, :error, message)}
    end
  end

  def handle_async(:action, {:exit, _reason}, socket) do
    {:noreply,
     socket
     |> assign(busy: nil)
     |> put_flash(:error, "Das hat nicht geklappt. Bitte erneut versuchen.")}
  end

  defp show(socket, overview) do
    selected =
      Enum.find_value(overview.plans, "", fn plan ->
        Enum.find_value(plan.accounts, &(&1.selected && &1.value))
      end)

    mapping = Map.new(overview.categories, &{"#{&1.id}", &1.selected || ""})

    assign(socket,
      overview: overview,
      target_form:
        to_form(%{"account" => selected, "start" => Date.to_iso8601(overview.start_date)},
          as: :target
        ),
      mapping_form: to_form(mapping, as: :mapping)
    )
  end

  defp account_options(plans) do
    for plan <- plans, do: {plan.name, Enum.map(plan.accounts, &{&1.name, &1.value})}
  end

  defp category_options(row, groups) do
    missing =
      if row.missing,
        do: [{"Nicht mehr vorhanden (in YNAB gelöscht oder versteckt)", row.selected}],
        else: []

    missing ++
      for(group <- groups, do: {group.name, Enum.map(group.categories, &{&1.name, &1.id})})
  end

  @impl true
  def render(assigns) do
    ~H"""
    <Layouts.app flash={@flash} current={:settings} participant={@current_participant}>
      <.header back={~p"/settings"} back_label="Einstellungen">
        YNAB
        <:subtitle>
          Deine Anteile an geteilten Ausgaben automatisch in dein eigenes YNAB übertragen.
        </:subtitle>
      </.header>

      <div class="flex flex-col gap-8">
        <section aria-labelledby="ynab-how" class="max-w-prose">
          <.section_heading id="ynab-how">So funktioniert’s</.section_heading>
          <ol class="list-decimal space-y-2 ps-5">
            <li>
              Lege in YNAB ein Konto <strong>„Geteilt“</strong>
              an (im Budget, z. B. Typ „Cash“). Als Startsaldo trägst du deinen Saldo in Zipfelkasse am Tag vor dem Startdatum ein.
            </li>
            <li>
              Zipfelkasse schreibt dort für jede geteilte Ausgabe <strong>nur deinen Anteil</strong>
              als Ausgabe – mit der YNAB-Kategorie aus der Zuordnung unten.
            </li>
            <li>
              Bezahlst du eine geteilte Ausgabe mit deiner Karte, markierst du die Buchung im Bankkonto als
              <strong>Transfer → „Geteilt“</strong>
              statt sie zu kategorisieren.
            </li>
            <li>
              Rückzahlungen (du überweist jemandem Geld oder bekommst welches) markierst du ebenso als Transfer zwischen Bankkonto und „Geteilt“. Zipfelkasse schreibt Rückzahlungen nicht selbst.
            </li>
          </ol>
          <p class="mt-3 text-base-content/70">
            Dann entspricht der Saldo von „Geteilt“ in YNAB deinem Saldo in Zipfelkasse (positiv: du bekommst Geld).
          </p>
        </section>

        <.alert :if={!@overview && !@failed} id="ynab-loading" tone={:neutral} busy>
          Die Verbindung zu YNAB wird geladen …
        </.alert>

        <.alert :if={@failed} id="ynab-failed" tone={:error}>
          Die YNAB-Einstellungen konnten nicht geladen werden.
          <:actions>
            <.button id="ynab-retry" patch={~p"/settings/ynab"} size={:sm}>Erneut versuchen</.button>
          </:actions>
        </.alert>

        <%= if @overview do %>
          <section aria-labelledby="ynab-connection">
            <.section_heading id="ynab-connection">Verbindung</.section_heading>
            <p class="mb-3 max-w-prose text-sm text-base-content/70">
              Persönlicher Zugriffstoken aus YNAB: Account Settings → Developer Settings → New Token. Er wird nur auf diesem Server gespeichert und nie wieder angezeigt.
            </p>
            <.alert :if={@overview.token_invalid} tone={:error} class="mb-3">
              Der gespeicherte Token ist ungültig oder abgelaufen. Bitte einen neuen eintragen.
            </.alert>
            <p :if={@overview.token_set && !@overview.token_invalid} class="mb-3">
              Token: <strong class="font-semibold">gesetzt</strong>
            </p>
            <.form for={@token_form} id="ynab-token-form" phx-submit="save_token">
              <.input
                field={@token_form[:token]}
                id={"connection_token-#{@saved_tokens}"}
                type="password"
                label={if @overview.token_set, do: "Token ersetzen", else: "Token"}
                placeholder={if @overview.token_set, do: "Neuer Token", else: "Token"}
                required
                maxlength="200"
                autocomplete="off"
                spellcheck="false"
                inline
              >
                <.button
                  id="ynab-token-submit"
                  type="submit"
                  variant={:primary}
                  loading={@busy == :token}
                  disabled={@busy != nil}
                  class="join-item"
                >
                  {if @overview.token_set, do: "Token ersetzen", else: "Verbinden"}
                </.button>
              </.input>
            </.form>
            <.button
              :if={@overview.token_set}
              id="ynab-disconnect"
              size={:sm}
              loading={@busy == :disconnect}
              disabled={@busy != nil}
              phx-click="disconnect"
              class="mt-3"
            >
              Verbindung trennen
            </.button>
          </section>

          <section
            :if={@overview.token_set && !@overview.token_invalid}
            aria-labelledby="ynab-target"
          >
            <.section_heading id="ynab-target">Plan und Konto</.section_heading>
            <p class="mb-3 max-w-prose text-sm text-base-content/70">
              Das Verrechnungskonto „Geteilt“ und ab wann deine Anteile übertragen werden.
            </p>
            <.alert :if={@overview.api_error} id="ynab-api-error" tone={:error} class="mb-3">
              {@overview.api_error}
            </.alert>
            <.alert :if={@overview.currency} tone={:warning} class="mb-3">
              Achtung: Dieser Plan rechnet in {@overview.currency}. Zipfelkasse überträgt Euro-Beträge.
            </.alert>
            <.form
              :if={@overview.plans != []}
              for={@target_form}
              id="ynab-target-form"
              phx-submit="choose_target"
            >
              <div class="grid gap-x-4 md:grid-cols-2">
                <.input
                  field={@target_form[:account]}
                  type="select"
                  label="Konto"
                  prompt="Bitte wählen …"
                  options={account_options(@overview.plans)}
                  required
                  help="Nur offene Konten im Budget. Bei einem Wechsel bleiben die bisherigen Buchungen im alten Konto; im neuen wird angelegt, was dort noch fehlt."
                />
                <.input
                  field={@target_form[:start]}
                  type="date"
                  label="Startdatum"
                  required
                  help="Übertragen werden Ausgaben ab diesem Datum (bis heute). Ältere Ausgaben, die du erst nach dem Einrichten nachträglich erfasst, werden auch übertragen – der Startsaldo kennt sie ja nicht. Schon übertragene Ausgaben bleiben in YNAB, auch wenn ihr Datum oder das Startdatum später verschoben wird."
                />
              </div>
              <.action_bar>
                <:secondary>
                  <.button patch={~p"/settings/ynab?refresh=1"} variant={:ghost} icon="refresh-cw">
                    Listen von YNAB neu laden
                  </.button>
                </:secondary>
                <.button
                  id="ynab-target-submit"
                  type="submit"
                  variant={:primary}
                  icon="save"
                  loading={@busy == :target}
                  disabled={@busy != nil}
                >
                  Speichern
                </.button>
              </.action_bar>
            </.form>
            <p :if={@overview.plans == [] && !@overview.api_error} class="max-w-prose text-sm">
              In deinem YNAB gibt es kein offenes Konto im Budget. Lege zuerst das Konto „Geteilt“ an und lade die <.link
                patch={~p"/settings/ynab?refresh=1"}
                class="link link-primary"
              >Liste neu</.link>.
            </p>
          </section>

          <section
            :if={@overview.has_target && @overview.categories != []}
            aria-labelledby="ynab-categories"
          >
            <.section_heading id="ynab-categories">Kategorien</.section_heading>
            <p class="mb-3 max-w-prose text-sm text-base-content/70">
              Welche YNAB-Kategorie bekommt dein Anteil? Ohne Zuordnung landet er unkategorisiert in YNAB.
            </p>
            <.form
              :if={@overview.groups != []}
              for={@mapping_form}
              id="ynab-mapping-form"
              phx-submit="map_categories"
            >
              <.table
                id="ynab-mapping"
                rows={@overview.categories}
                row_id={&"ynab-mapping-#{&1.id}"}
                size={:dense}
              >
                <:col :let={row} label="In Zipfelkasse">
                  {row.name}
                  <span :if={row.archived} class="text-base-content/70">(archiviert)</span>
                </:col>
                <:col :let={row} label="In YNAB">
                  <.input
                    field={@mapping_form["#{row.id}"]}
                    type="select"
                    label={"YNAB-Kategorie für #{row.name}"}
                    hide_label
                    prompt="– unkategorisiert –"
                    options={category_options(row, @overview.groups)}
                  />
                </:col>
              </.table>
              <.action_bar>
                <.button
                  id="ynab-mapping-submit"
                  type="submit"
                  variant={:primary}
                  icon="save"
                  loading={@busy == :mapping}
                  disabled={@busy != nil}
                >
                  Zuordnung speichern
                </.button>
              </.action_bar>
            </.form>
            <p :if={@overview.groups == []} class="text-sm">
              Die Kategorien aus YNAB konnten nicht geladen werden.
            </p>
          </section>

          <section :if={@overview.token_set} aria-labelledby="ynab-status">
            <.section_heading id="ynab-status">Status</.section_heading>
            <.description_list id="ynab-facts">
              <:item label="Dein Saldo in Zipfelkasse">
                <.amount value={@overview.balance} signed tone class="font-semibold" />
              </:item>
              <:item :if={@overview.ready} label="Synchronisierte Buchungen">
                {@overview.synced}
              </:item>
              <:item
                :if={@overview.ready && @overview.connection.last_synced_at}
                label="Letzter Abgleich"
              >
                <.local_time at={@overview.connection.last_synced_at} />
                <span :if={@overview.connection.summary} class="text-base-content/70">
                  ({@overview.connection.summary})
                </span>
              </:item>
            </.description_list>
            <p class="mt-2 text-sm text-base-content/70">
              So viel sollte auch „Geteilt“ in YNAB zeigen.
            </p>
            <p :if={!@overview.ready} class="mt-3 max-w-prose text-sm">
              Sobald Plan, Konto und Startdatum gewählt sind, synchronisiert Zipfelkasse automatisch: kurz nach jeder Änderung und stündlich.
            </p>
            <p :if={@overview.ready && !@overview.connection.last_synced_at} class="mt-3 text-sm">
              Noch nicht synchronisiert.
            </p>
            <.alert :if={@overview.connection.error} id="ynab-sync-error" tone={:error} class="mt-3">
              {@overview.connection.error}
            </.alert>
            <p :if={@overview.retry_at} class="mt-3 text-sm text-base-content/70">
              Nächster Versuch ab <.local_time at={@overview.retry_at} />.
            </p>

            <div :if={@overview.problems != []} class="mt-6">
              <.section_heading size={:sm}>Fehler bei einzelnen Ausgaben</.section_heading>
              <.table
                id="ynab-problems"
                rows={@overview.problems}
                row_id={&"ynab-problem-#{&1.expense_id}"}
                row_link={&~p"/expenses/#{&1.expense_id}"}
                size={:sm}
              >
                <:col :let={problem} label="Ausgabe">
                  {problem.title}
                  <.cell_sub hide_from={:sm}>{Format.date(problem.date)}</.cell_sub>
                </:col>
                <:col :let={problem} label="Datum" align={:end} show_from={:sm}>
                  {Format.date(problem.date)}
                </:col>
                <:col :let={problem} label="Fehler">{problem.error}</:col>
              </.table>
            </div>

            <.button
              :if={@overview.ready}
              id="ynab-sync"
              icon="refresh-cw"
              loading={@busy == :sync}
              disabled={@busy != nil}
              phx-click="sync_now"
              class="mt-6"
            >
              Jetzt synchronisieren
            </.button>
          </section>
        <% end %>
      </div>
    </Layouts.app>
    """
  end
end
