defmodule ZipfelkasseWeb.BalancesLive do
  @moduledoc """
  Who paid more or less than their share, as bars to either side of zero, and the transfers
  that settle everything; each one opens the reimbursement form prefilled.
  """
  use ZipfelkasseWeb, :live_view

  alias Zipfelkasse.{Balances, Expenses, Ledger, Participants}

  @impl true
  def mount(_params, _session, socket) do
    if connected?(socket), do: Expenses.subscribe()
    {:ok, socket |> assign(page_title: Layouts.page_title("Salden")) |> load()}
  end

  @impl true
  def handle_info({:expenses_changed, _ids}, socket), do: {:noreply, load(socket)}

  defp load(socket) do
    balances = Balances.balances()
    people = Participants.list_participants(:all)
    by_id = Map.new(people, &{&1.id, &1})

    rows =
      for person <- people,
          cents = Map.get(balances, person.id, 0),
          is_nil(person.archived_at) or cents != 0,
          do: %{person: person, cents: cents}

    largest = rows |> Enum.map(&abs(&1.cents)) |> Enum.max(fn -> 0 end)

    transfers =
      for transfer <- Ledger.settle(balances) do
        Map.merge(transfer, %{from_person: by_id[transfer.from], to_person: by_id[transfer.to]})
      end

    assign(socket,
      rows: Enum.map(rows, &Map.put(&1, :width, width(&1.cents, largest))),
      transfers: transfers
    )
  end

  # Percent of half the bar, at least 1 so that a cent still shows.
  defp width(0, _largest), do: 0
  defp width(cents, largest), do: max(1, div(abs(cents) * 100 + div(largest, 2), largest))

  defp summary(rows) do
    "Salden: " <>
      Enum.map_join(rows, ", ", &"#{name(&1.person)} #{Format.money(&1.cents, signed: true)}")
  end

  defp name(%{archived_at: nil, name: name}), do: name
  defp name(%{name: name}), do: "#{name} (archiviert)"

  @impl true
  def render(assigns) do
    ~H"""
    <Layouts.app flash={@flash} current={:balances} participant={@current_participant}>
      <.header>Salden</.header>

      <div class="flex flex-col gap-8">
        <.chart_card
          id="balance-chart"
          title="Saldo pro Person"
          subtitle="So viel hat jede Person mehr oder weniger bezahlt, als ihr Anteil war."
          summary={summary(@rows)}
          height={:auto}
        >
          <div class="flex flex-col gap-3 py-2 text-sm">
            <div
              :for={row <- @rows}
              id={"balance-#{row.person.id}"}
              class="grid grid-cols-[minmax(0,7rem)_minmax(0,1fr)_auto] items-center gap-3 sm:grid-cols-[minmax(0,10rem)_minmax(0,1fr)_auto]"
            >
              <span class={[
                "truncate",
                row.person.id == @current_participant.id && "font-semibold"
              ]}>
                {name(row.person)}
              </span>
              <svg
                viewBox="0 0 200 12"
                preserveAspectRatio="none"
                class="h-3 w-full overflow-visible"
                aria-hidden="true"
              >
                <line
                  x1="100"
                  y1="-2"
                  x2="100"
                  y2="14"
                  class="stroke-base-content/30"
                  stroke-width="1"
                  vector-effect="non-scaling-stroke"
                />
                <rect
                  :if={row.width > 0}
                  x={if row.cents > 0, do: 100, else: 100 - row.width}
                  y="0"
                  width={row.width}
                  height="12"
                  class={
                    if row.cents > 0,
                      do: "fill-chart-3-fill stroke-chart-3",
                      else: "fill-chart-4-fill stroke-chart-4"
                  }
                  stroke-width="1"
                  vector-effect="non-scaling-stroke"
                />
              </svg>
              <.amount value={row.cents} signed tone class="text-end" />
            </div>
          </div>
          <:legend>
            <.legend items={[
              %{label: "mehr bezahlt", color: 3},
              %{label: "weniger bezahlt", color: 4}
            ]} />
          </:legend>
          <:data>
            <.table id="balance-data" rows={@rows} size={:sm} flush>
              <:col :let={row} label="Person">{name(row.person)}</:col>
              <:col :let={row} label="Saldo" align={:end}>
                <.amount value={row.cents} signed />
              </:col>
            </.table>
          </:data>
        </.chart_card>

        <section aria-labelledby="transfers">
          <.section_heading id="transfers">Vorgeschlagene Rückzahlungen</.section_heading>
          <p class="max-w-prose text-sm text-base-content/70">
            Mit diesen Zahlungen ist alles ausgeglichen. Nach dem Überweisen „Als erstattet markieren“ – dann wird die Rückzahlung eingetragen.
          </p>
          <.list :if={@transfers != []} id="transfer-list" class="mt-3">
            <.list_row
              :for={{transfer, index} <- Enum.with_index(@transfers)}
              id={"transfer-#{index}"}
              title={"#{transfer.from_person.name} schuldet #{transfer.to_person.name}"}
            >
              <:trailing>
                <.amount value={transfer.amount_cents} class="font-semibold" />
                <.button
                  id={"transfer-#{index}-settle"}
                  size={:sm}
                  navigate={
                    ~p"/expenses/new?#{[reimbursement: 1, from: transfer.from, to: transfer.to, amount: transfer.amount_cents]}"
                  }
                >
                  Als erstattet markieren
                </.button>
              </:trailing>
            </.list_row>
          </.list>
          <.empty_state
            :if={@transfers == []}
            plush="scale"
            title="Alles ausgeglichen – niemand muss etwas zurückzahlen."
          />
        </section>
      </div>
    </Layouts.app>
    """
  end
end
