defmodule ZipfelkasseWeb.ActivityLive do
  @moduledoc """
  Who created, changed or deleted what, newest first under period headings, 50 at a time.
  Changes to expenses show at once.
  """
  use ZipfelkasseWeb, :live_view

  alias Zipfelkasse.{Activities, Expenses, LocalTime, Periods}
  alias ZipfelkasseWeb.PeriodHeadings

  @page_size 50

  @impl true
  def mount(_params, _session, socket) do
    if connected?(socket), do: Expenses.subscribe()

    {:ok,
     socket
     |> assign(
       page_title: Layouts.page_title("Aktivität"),
       before_id: nil,
       last_heading: nil,
       shown: 0
     )
     |> stream_configure(:entries, dom_id: & &1.dom_id)
     |> load(@page_size)}
  end

  @impl true
  def handle_event("older", _params, socket) do
    if socket.assigns.before_id,
      do: {:noreply, load(socket, @page_size)},
      else: {:noreply, socket}
  end

  @impl true
  def handle_info({:expenses_changed, _ids}, socket) do
    count = max(socket.assigns.shown, @page_size)

    {:noreply,
     socket
     |> assign(before_id: nil, last_heading: nil, shown: 0)
     |> load(count, reset: true)}
  end

  defp load(socket, count, opts \\ []) do
    activities = Activities.list_activities(limit: count + 1, before_id: socket.assigns.before_id)

    {page, more?} =
      if length(activities) > count,
        do: {Enum.take(activities, count), true},
        else: {activities, false}

    today = LocalTime.today()

    {entries, last_heading} =
      PeriodHeadings.rows(
        page,
        socket.assigns.last_heading,
        &Periods.activity_heading(LocalTime.date(&1.inserted_at), today),
        &%{kind: :entry, dom_id: "activity-#{&1.id}", activity: &1}
      )

    socket
    |> assign(
      before_id: if(more?, do: List.last(page).id),
      last_heading: last_heading,
      shown: socket.assigns.shown + length(page),
      empty?: socket.assigns.before_id == nil and page == []
    )
    |> stream(:entries, entries, opts)
  end

  @impl true
  def render(assigns) do
    ~H"""
    <Layouts.app flash={@flash} current={:activity} participant={@current_participant}>
      <.header>
        Aktivität
        <:subtitle>Wer hat wann was angelegt, geändert oder gelöscht.</:subtitle>
      </.header>

      <.list
        id="activities"
        class={@empty? && "hidden"}
        phx-update="stream"
        phx-viewport-bottom={@before_id && "older"}
      >
        <%= for {dom_id, item} <- @streams.entries do %>
          <.list_heading :if={item.kind == :heading} id={dom_id}>{item.label}</.list_heading>
          <.activity_entry :if={item.kind == :entry} id={dom_id} activity={item.activity} link />
        <% end %>
      </.list>

      <.empty_state :if={@empty?} plush="activity" title="Noch keine Aktivität." />

      <div :if={@before_id} class="pt-4">
        <.button id="activities-older" phx-click="older" phx-disable-with="Lädt …">
          Ältere anzeigen
        </.button>
      </div>
    </Layouts.app>
    """
  end
end
