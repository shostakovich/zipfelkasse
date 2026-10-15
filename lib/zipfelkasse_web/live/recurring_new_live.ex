defmodule ZipfelkasseWeb.RecurringNewLive do
  @moduledoc """
  Makes an expense recurring (`?expense_id=`): the expense as template and first date, and how
  often, with the next date and what the catch-up would enter or skip for each frequency.
  """
  use ZipfelkasseWeb, :live_view

  alias Zipfelkasse.{Expenses, Money, Recurring, Split}
  alias Zipfelkasse.Expenses.Expense
  alias ZipfelkasseWeb.Params

  @frequencies Map.new(Recurring.frequencies(), &{Atom.to_string(&1), &1})

  @impl true
  def mount(params, _session, socket) do
    socket = assign(socket, page_title: Layouts.page_title("Wiederkehrende Ausgabe anlegen"))

    case params["expense_id"] do
      blank when blank in [nil, ""] -> {:ok, assign(socket, expense: nil)}
      id -> {:ok, socket |> assign(expense: fetch_expense(id)) |> assign_choice("monthly", [])}
    end
  end

  defp fetch_expense(id) do
    with id when is_integer(id) <- Params.positive_integer(id),
         %Expense{deleted_at: nil} = expense <- Expenses.get_expense(id) do
      expense
    else
      _missing -> raise ZipfelkasseWeb.NotFoundError, "Ausgabe nicht gefunden."
    end
  end

  defp assign_choice(socket, frequency, errors) do
    assign(socket,
      previews: Recurring.previews(socket.assigns.expense),
      form: to_form(%{"frequency" => frequency}, as: :recurring, errors: errors)
    )
  end

  @impl true
  def handle_event("recover", params, socket),
    do: {:noreply, assign_choice(socket, get_in(params, ["recurring", "frequency"]) || "", [])}

  def handle_event("create", params, socket) do
    frequency = get_in(params, ["recurring", "frequency"]) || ""
    %{current_participant: me, expense: expense} = socket.assigns

    case Map.fetch(@frequencies, frequency) do
      {:ok, frequency} ->
        create(socket, Recurring.create_rule(me.id, expense, frequency), frequency)

      :error ->
        errors = [frequency: {"Bitte eine Häufigkeit wählen.", []}]
        {:noreply, assign_choice(socket, frequency, errors)}
    end
  end

  defp create(socket, {:ok, _rule, created}, frequency) do
    title = socket.assigns.expense.title
    message = "„#{title}“ wiederholt sich jetzt #{Recurring.adverb(frequency)}."

    message =
      if created > 0, do: "#{message} #{expense_count(created)} nachgetragen.", else: message

    {:noreply, socket |> put_flash(:info, message) |> push_navigate(to: ~p"/settings/recurring")}
  end

  defp create(socket, {:error, :already_recurring}, _frequency) do
    {:noreply,
     socket
     |> put_flash(:error, "Diese Ausgabe gehört schon zu einer wiederkehrenden Ausgabe.")
     |> assign(expense: Expenses.get_expense(socket.assigns.expense.id))}
  end

  defp create(socket, {:error, :not_found}, _frequency) do
    {:noreply, socket |> put_flash(:error, "Ausgabe nicht gefunden.") |> push_navigate(to: ~p"/")}
  end

  @doc """
  What making the rule enters or skips, from a preview's `missed` dates up to today and the
  `existing` ones among them; "" when nothing.
  """
  @spec note(%{missed: non_neg_integer(), existing: non_neg_integer()}) :: String.t()
  def note(%{missed: missed, existing: existing}) do
    capped? = missed > Recurring.max_missed()

    [entered(missed, missed - existing, capped?), skipped(existing, capped?)]
    |> Enum.reject(&is_nil/1)
    |> Enum.join("; ")
  end

  defp entered(missed, new, capped?) do
    per_run = Recurring.max_per_run()

    entered =
      if missed > per_run,
        do:
          "eingetragen – die ersten #{per_run} Termine sofort, der Rest in den nächsten Stunden",
        else: "sofort eingetragen"

    cond do
      capped? -> "mehr als #{Recurring.max_missed()} verpasste Termine werden #{entered}"
      new == 1 -> "1 verpasster Termin wird #{entered}"
      new > 1 -> "#{new} verpasste Termine werden #{entered}"
      true -> nil
    end
  end

  defp skipped(0, _capped?), do: nil

  defp skipped(existing, capped?) do
    at_least = if capped?, do: "mindestens ", else: ""

    if existing == 1,
      do: "#{at_least}1 bereits als Ausgabe vorhandener Termin wird übersprungen",
      else: "#{at_least}#{existing} bereits als Ausgabe vorhandene Termine werden übersprungen"
  end

  @impl true
  def render(assigns) do
    ~H"""
    <Layouts.app
      flash={@flash}
      current={:settings}
      participant={@current_participant}
      fab={is_nil(@expense)}
    >
      <.header
        back={if @expense, do: ~p"/expenses/#{@expense}", else: ~p"/settings/recurring"}
        back_label={if @expense, do: "Ausgabe", else: "Wiederkehrende Ausgaben"}
      >
        Wiederkehrende Ausgabe anlegen
        <:subtitle :if={@expense}>
          Die Ausgabe dient als Vorlage und ist der erste Termin. Weitere Termine werden automatisch mit denselben Angaben eingetragen.
        </:subtitle>
      </.header>

      <%= if @expense do %>
        <.description_list id="recurring-expense">
          <:item label="Titel"><strong class="font-semibold">{@expense.title}</strong></:item>
          <:item label="Betrag">
            <%= if Expense.foreign?(@expense) do %>
              <.amount
                value={@expense.original_amount}
                currency={@expense.original_currency}
                minor_digits={Money.decimals(@expense.original_currency)}
                currency_display={:code}
              /> (<.amount value={@expense.amount_cents} />; künftig zum Kurs des jeweiligen Tages)
            <% else %>
              <.amount value={@expense.amount_cents} />
            <% end %>
          </:item>
          <:item label="Bezahlt von">{@expense.paid_by.name}</:item>
          <:item :if={@expense.category} label="Kategorie">{@expense.category.name}</:item>
          <:item label="Aufteilung">{Split.label(@expense.split_mode)}</:item>
          <:item :if={@expense.notes != ""} label="Notiz">{@expense.notes}</:item>
          <:item label="Erster Termin">{Format.date(@expense.date)}</:item>
        </.description_list>

        <div :if={@expense.recurring_expense_id} id="recurring-exists" class="mt-8">
          <p>Diese Ausgabe gehört schon zu einer wiederkehrenden Ausgabe.</p>
          <.button navigate={~p"/settings/recurring"} class="mt-3">
            Zu den wiederkehrenden Ausgaben
          </.button>
        </div>

        <.form
          :if={!@expense.recurring_expense_id}
          for={@form}
          id="recurring-form"
          phx-submit="create"
          phx-auto-recover="recover"
          class="mt-8"
        >
          <.input
            field={@form[:frequency]}
            type="radio_group"
            label="Wie oft?"
            options={Enum.map(@previews, &frequency_option/1)}
          />
          <.action_bar>
            <.button navigate={~p"/expenses/#{@expense}"}>Abbrechen</.button>
            <.button
              id="recurring-submit"
              type="submit"
              variant={:primary}
              icon="repeat"
              phx-disable-with="Richtet ein …"
            >
              Als wiederkehrend einrichten
            </.button>
          </.action_bar>
        </.form>
      <% else %>
        <p class="max-w-prose">
          Öffne zuerst die Ausgabe, die sich wiederholen soll, und wähle dort „Als wiederkehrend einrichten“.
        </p>
        <.button navigate={~p"/"} class="mt-4">Zu den Ausgaben</.button>
      <% end %>
    </Layouts.app>
    """
  end

  defp frequency_option(preview) do
    next = "Nächster Termin #{Format.date(preview.next_date)}"

    %{
      label: Recurring.frequency_label(preview.frequency),
      value: Atom.to_string(preview.frequency),
      description: Enum.join(Enum.reject([next, note(preview)], &(&1 == "")), "; ")
    }
  end
end
