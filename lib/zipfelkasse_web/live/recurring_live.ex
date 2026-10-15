defmodule ZipfelkasseWeb.RecurringLive do
  @moduledoc """
  The recurring expenses: how often, since when, who pays and the next date; pause and resume,
  take the template from the newest occurrence, delete.
  """
  use ZipfelkasseWeb, :live_view

  alias Zipfelkasse.{Categories, Money, Participants, Recurring}
  alias Zipfelkasse.Recurring.RecurringExpense
  alias ZipfelkasseWeb.CategoryIcon

  @impl true
  def mount(_params, _session, socket),
    do:
      {:ok, socket |> assign(page_title: Layouts.page_title("Wiederkehrende Ausgaben")) |> load()}

  defp load(socket) do
    people = Map.new(Participants.list_participants(:all), &{&1.id, &1.name})
    categories = Map.new(Categories.list_categories(:all), &{&1.id, &1})

    rows =
      for %{template: template} = rule <- Recurring.list_rules() do
        %{
          rule: rule,
          payer: people[template.paid_by_id],
          plush:
            CategoryIcon.for_expense(%{
              reimbursement: template.reimbursement,
              category: categories[template.category_id]
            })
        }
      end

    assign(socket, rows: rows)
  end

  @impl true
  def handle_event("pause", %{"id" => id}, socket) do
    with_rule(socket, id, fn rule, me ->
      case Recurring.pause_rule(me, rule) do
        {:ok, _rule} -> put_flash(socket, :info, "Pausiert.")
        {:error, :not_found} -> not_found(socket)
      end
    end)
  end

  def handle_event("resume", %{"id" => id}, socket) do
    with_rule(socket, id, fn rule, me ->
      case Recurring.resume_rule(me, rule) do
        {:ok, _rule, 0} ->
          put_flash(socket, :info, "Fortgesetzt.")

        {:ok, _rule, created} ->
          put_flash(socket, :info, "Fortgesetzt. #{expense_count(created)} angelegt.")

        {:error, :not_found} ->
          not_found(socket)
      end
    end)
  end

  def handle_event("refresh_template", %{"id" => id}, socket) do
    with_rule(socket, id, fn rule, me ->
      case Recurring.refresh_template(me, rule) do
        {:ok, _rule} ->
          put_flash(socket, :info, "Vorlage aus der letzten Ausgabe übernommen.")

        {:error, :no_occurrence} ->
          put_flash(
            socket,
            :error,
            "Es gibt keine Ausgabe dieser Wiederholung mehr, aus der die Vorlage übernommen werden könnte."
          )

        {:error, :not_found} ->
          not_found(socket)
      end
    end)
  end

  def handle_event("delete", %{"id" => id}, socket) do
    with_rule(socket, id, fn rule, me ->
      case Recurring.delete_rule(me, rule) do
        {:ok, _rule} ->
          put_flash(
            socket,
            :info,
            "Wiederholung gelöscht. Bereits angelegte Ausgaben bleiben erhalten."
          )

        {:error, :not_found} ->
          not_found(socket)
      end
    end)
  end

  defp with_rule(socket, id, fun) do
    socket =
      case Recurring.get_rule(id) do
        %RecurringExpense{} = rule -> fun.(rule, socket.assigns.current_participant.id)
        nil -> not_found(socket)
      end

    {:noreply, load(socket)}
  end

  defp not_found(socket), do: put_flash(socket, :error, "Wiederkehrende Ausgabe nicht gefunden.")

  @impl true
  def render(assigns) do
    ~H"""
    <Layouts.app flash={@flash} current={:settings} participant={@current_participant}>
      <.header back={~p"/settings"} back_label="Einstellungen">
        Wiederkehrende Ausgaben
        <:subtitle>
          Eine wiederkehrende Ausgabe legst du bei einer bestehenden Ausgabe über „Als wiederkehrend einrichten“ an. Fällige Termine werden automatisch als Ausgaben eingetragen – auch verpasste. Gibt es an einem Termin schon eine Ausgabe mit gleichem Titel, Betrag und Zahler, wird er übersprungen. Pausierte Termine werden beim Fortsetzen nicht nachgeholt.
        </:subtitle>
      </.header>

      <.list :if={@rows != []} id="rules">
        <.list_row
          :for={%{rule: rule} = row <- @rows}
          id={"rule-#{rule.id}"}
          title={rule.template.title}
          menu={:always}
          trailing_on_phone={:title}
        >
          <:leading><.plush name={row.plush} size={:lg} /></:leading>
          <:meta>
            {Recurring.frequency_label(rule.frequency)} seit {Format.date(rule.start_date)}
          </:meta>
          <:meta :if={row.payer}>Zahlt {row.payer}</:meta>
          <:meta>
            <span :if={rule.active}>Nächster Termin {Format.date(rule.next_date)}</span>
            <.badge :if={!rule.active}>pausiert</.badge>
          </:meta>
          <:trailing>
            <.amount
              :if={Money.eur?(rule.template.original_currency)}
              value={rule.template.amount_cents}
              class="font-semibold"
            />
            <.amount
              :if={!Money.eur?(rule.template.original_currency)}
              value={rule.template.original_amount}
              currency={rule.template.original_currency}
              minor_digits={Money.decimals(rule.template.original_currency)}
              currency_display={:code}
              class="font-semibold"
            />
          </:trailing>
          <:action
            :if={rule.active}
            id={"rule-#{rule.id}-pause"}
            label="Pausieren"
            icon="pause"
            inline
            on_click={JS.push("pause", value: %{id: rule.id})}
          />
          <:action
            :if={!rule.active}
            id={"rule-#{rule.id}-resume"}
            label="Fortsetzen"
            icon="play"
            inline
            on_click={JS.push("resume", value: %{id: rule.id})}
          />
          <:action
            id={"rule-#{rule.id}-template"}
            label="Vorlage aktualisieren"
            icon="refresh-cw"
            on_click={JS.push("refresh_template", value: %{id: rule.id})}
          />
          <:action
            id={"rule-#{rule.id}-delete"}
            label="Löschen"
            icon="trash-2"
            danger
            confirm={"Wiederholung von „#{rule.template.title}“ löschen?"}
            confirm_text="Bereits eingetragene Ausgaben bleiben erhalten."
            on_click={JS.push("delete", value: %{id: rule.id})}
          />
        </.list_row>
      </.list>

      <.empty_state
        :if={@rows == []}
        plush="repeat"
        title="Noch keine wiederkehrenden Ausgaben."
      />
    </Layouts.app>
    """
  end
end
