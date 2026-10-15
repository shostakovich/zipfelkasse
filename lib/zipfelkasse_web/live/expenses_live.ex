defmodule ZipfelkasseWeb.ExpensesLive do
  @moduledoc """
  The expenses of the group, newest first under period headings, with the reader's balance,
  a search by text, category and person, and 100 more at a time. Changes by others show at once.
  """
  use ZipfelkasseWeb, :live_view

  alias Zipfelkasse.{Balances, Categories, Expenses, LocalTime, Money, Participants, Periods}
  alias Zipfelkasse.Expenses.Expense
  alias ZipfelkasseWeb.{CategoryIcon, Params, PeriodHeadings}

  @page_size 100

  @impl true
  def mount(_params, _session, socket) do
    if connected?(socket), do: Expenses.subscribe()

    {:ok,
     socket
     |> assign(page_title: Layouts.page_title("Ausgaben"))
     |> stream_configure(:rows, dom_id: & &1.dom_id)
     |> assign_balance()}
  end

  @impl true
  def handle_params(params, _uri, socket) do
    filter = %{
      q: String.trim(params["q"] || ""),
      category_id: Params.positive_integer(params["category"]),
      person_id: Params.positive_integer(params["person"])
    }

    {:noreply,
     socket
     |> assign(filter: filter, filter_form: filter_form(filter))
     |> assign_choices(filter)
     |> load(@page_size)}
  end

  @impl true
  def handle_event("filter", params, socket) do
    query =
      for key <- ~w(q category person),
          value = String.trim(params[key] || ""),
          value != "",
          do: {key, value}

    {:noreply, push_patch(socket, to: ~p"/?#{query}", replace: true)}
  end

  def handle_event("more", _params, socket) do
    if socket.assigns.cursor,
      do: {:noreply, append(socket, @page_size)},
      else: {:noreply, socket}
  end

  @impl true
  def handle_info({:expenses_changed, _ids}, socket) do
    {:noreply,
     socket
     |> assign_balance()
     |> assign_choices(socket.assigns.filter)
     |> load(max(socket.assigns.shown, @page_size))}
  end

  defp filter_form(filter) do
    to_form(%{
      "q" => filter.q,
      "category" => filter.category_id,
      "person" => filter.person_id
    })
  end

  defp filter_active?(filter),
    do: filter.q != "" or not is_nil(filter.category_id) or not is_nil(filter.person_id)

  defp assign_balance(socket) do
    assign(socket, :balance, Balances.balance(socket.assigns.current_participant.id))
  end

  defp assign_choices(socket, filter) do
    people = Participants.list_participants(:all)

    assign(socket,
      names: Map.new(people, &{&1.id, &1.name}),
      active_ids: for(p <- people, is_nil(p.archived_at), into: MapSet.new(), do: p.id),
      people: for(p <- people, is_nil(p.archived_at) or p.id == filter.person_id, do: p),
      categories:
        for(
          c <- Categories.list_categories(:all),
          is_nil(c.archived_at) or c.id == filter.category_id,
          do: c
        )
    )
  end

  defp load(socket, count) do
    {expenses, cursor} = fetch(socket.assigns.filter, count, nil)
    {rows, last_heading} = rows(socket, expenses, nil)

    socket
    |> assign(cursor: cursor, shown: length(expenses), last_heading: last_heading)
    |> assign(empty?: expenses == [])
    |> stream(:rows, rows, reset: true)
  end

  defp append(socket, count) do
    {expenses, cursor} = fetch(socket.assigns.filter, count, socket.assigns.cursor)
    {rows, last_heading} = rows(socket, expenses, socket.assigns.last_heading)

    socket
    |> assign(cursor: cursor, shown: socket.assigns.shown + length(expenses))
    |> assign(last_heading: last_heading)
    |> stream(:rows, rows)
  end

  defp fetch(filter, count, cursor) do
    filters = [
      q: if(filter.q != "", do: filter.q),
      category_id: filter.category_id,
      participant_id: filter.person_id
    ]

    case Expenses.list_expenses(filters, limit: count + 1, after: cursor) do
      expenses when length(expenses) > count ->
        page = Enum.take(expenses, count)
        last = List.last(page)
        {page, {last.date, last.id}}

      expenses ->
        {expenses, nil}
    end
  end

  defp rows(socket, expenses, last_heading) do
    today = LocalTime.today()

    PeriodHeadings.rows(
      expenses,
      last_heading,
      &Periods.expense_heading(&1.date, today),
      &row(socket.assigns, &1)
    )
  end

  defp row(assigns, %Expense{} = expense) do
    me = assigns.current_participant.id
    share = Expense.share_of(expense, me)
    paid = if expense.paid_by_id == me, do: expense.amount_cents, else: 0

    %{
      kind: :expense,
      dom_id: "expense-#{expense.id}",
      expense: expense,
      plush: CategoryIcon.for_expense(expense),
      who: who(assigns, expense),
      involved?:
        expense.paid_by_id == me or Enum.any?(expense.shares, &(&1.participant_id == me)),
      balance: paid - share
    }
  end

  defp who(assigns, %Expense{reimbursement: true} = expense) do
    recipient = expense.shares |> List.first() |> then(&(&1 && assigns.names[&1.participant_id]))
    "#{assigns.names[expense.paid_by_id]} an #{recipient}"
  end

  defp who(assigns, expense) do
    ids = Enum.map(expense.shares, & &1.participant_id)

    whom =
      if MapSet.size(assigns.active_ids) >= 4 and
           MapSet.equal?(MapSet.new(ids), assigns.active_ids),
         do: "alle",
         else: Enum.map_join(ids, ", ", &assigns.names[&1])

    "Bezahlt von #{assigns.names[expense.paid_by_id]} für #{whom}"
  end

  @impl true
  def render(assigns) do
    ~H"""
    <Layouts.app flash={@flash} current={:expenses} participant={@current_participant}>
      <.header>
        Ausgaben
        <:subtitle>Alle Ausgaben und Rückzahlungen der Gruppe.</:subtitle>
        <:actions>
          <.button
            navigate={~p"/expenses/new"}
            variant={:primary}
            icon="plus"
            class="max-md:hidden"
          >
            Neue Ausgabe
          </.button>
        </:actions>
      </.header>

      <div class="grid">
        <.stat
          id="my-balance"
          label="Dein Saldo"
          navigate={~p"/balances"}
          tone={balance_tone(@balance)}
          desc={balance_text(@balance)}
        >
          <.amount value={@balance} signed />
          <:figure><.plush name="scale" size={:lg} /></:figure>
        </.stat>
      </div>

      <.form
        for={@filter_form}
        id="expense-filter"
        role="search"
        phx-change="filter"
        phx-submit="filter"
        class="mt-6 grid grid-cols-2 gap-3 md:grid-cols-[minmax(0,2fr)_minmax(0,1fr)_minmax(0,1fr)]"
      >
        <div class="col-span-2 md:col-span-1">
          <.input
            field={@filter_form[:q]}
            type="search"
            label="Suche"
            hide_label
            icon="search"
            placeholder="Nach einer Ausgabe suchen …"
            maxlength="200"
            enterkeyhint="search"
            phx-debounce="300"
          />
        </div>
        <.input
          field={@filter_form[:category]}
          type="select"
          label="Kategorie"
          hide_label
          prompt="Alle Kategorien"
          options={Enum.map(@categories, &{&1.name, &1.id})}
        />
        <.input
          field={@filter_form[:person]}
          type="select"
          label="Person"
          hide_label
          prompt="Alle Personen"
          options={Enum.map(@people, &{&1.name, &1.id})}
        />
      </.form>
      <div :if={filter_active?(@filter)} class="mt-2">
        <.button patch={~p"/"} variant={:ghost} size={:sm} class="-ms-3">
          Filter zurücksetzen
        </.button>
      </div>

      <.list
        id="expenses"
        class={["mt-6", @empty? && "hidden"]}
        phx-update="stream"
        phx-viewport-bottom={@cursor && "more"}
      >
        <%= for {dom_id, row} <- @streams.rows do %>
          <.list_heading :if={row.kind == :heading} id={dom_id}>{row.label}</.list_heading>
          <.list_row
            :if={row.kind == :expense}
            id={dom_id}
            navigate={~p"/expenses/#{row.expense}"}
            trailing_on_phone={:title}
          >
            <:leading><.plush name={row.plush} size={:lg} /></:leading>
            {row.expense.title}<.badge
              :if={row.expense.recurring_expense_id}
              icon="repeat"
              label="Wiederkehrend"
              class="ms-1.5 align-text-bottom"
            />
            <:meta>{row.who}</:meta>
            <:meta>
              <span class="md:hidden">{Format.date(row.expense.date)}<.meta_sep /></span>
              <span :if={row.involved?}>
                Dein Saldo: <.amount value={row.balance} signed tone={:negative} />
              </span>
              <span :if={!row.involved?}>Du bist nicht beteiligt</span>
            </:meta>
            <:trailing :let={place}>
              <div class="flex flex-col items-end text-end">
                <.amount value={row.expense.amount_cents} class="font-semibold" />
                <.amount
                  :if={Expense.foreign?(row.expense)}
                  value={row.expense.original_amount}
                  currency={row.expense.original_currency}
                  minor_digits={Money.decimals(row.expense.original_currency)}
                  currency_display={:code}
                  class="text-sm text-base-content/70"
                />
                <span :if={place == :column} class="text-sm text-base-content/70 tabular-nums">
                  {Format.date(row.expense.date)}
                </span>
              </div>
            </:trailing>
          </.list_row>
        <% end %>
      </.list>

      <%= if @empty? do %>
        <.empty_state :if={filter_active?(@filter)} plush="receipt" title="Keine Ausgaben gefunden.">
          <:action>
            <.button patch={~p"/"} size={:sm}>Filter zurücksetzen</.button>
          </:action>
        </.empty_state>
        <.empty_state :if={!filter_active?(@filter)} plush="receipt" title="Noch keine Ausgaben.">
          <:action>
            <.button navigate={~p"/expenses/new"} variant={:primary} icon="plus" size={:sm}>
              Erste Ausgabe anlegen
            </.button>
          </:action>
        </.empty_state>
      <% end %>

      <div :if={@cursor} class="pt-4">
        <.button id="expenses-more" phx-click="more" phx-disable-with="Lädt …">
          Weitere anzeigen
        </.button>
      </div>
    </Layouts.app>
    """
  end

  defp balance_tone(balance) when balance > 0, do: :success
  defp balance_tone(balance) when balance < 0, do: :error
  defp balance_tone(_balance), do: nil

  defp balance_text(balance) when balance > 0, do: "Du bekommst noch Geld."
  defp balance_text(balance) when balance < 0, do: "Du schuldest noch Geld."
  defp balance_text(_balance), do: "Alles ausgeglichen."
end
