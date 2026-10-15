defmodule ZipfelkasseWeb.SettingsLive do
  @moduledoc """
  The group's name, the colour scheme of this browser and the way to the other settings.
  """
  use ZipfelkasseWeb, :live_view

  alias Zipfelkasse.Settings

  @links [
    {"participants", "Teilnehmer", "users", "/settings/participants"},
    {"categories", "Kategorien", "tag", "/settings/categories"},
    {"recurring", "Wiederkehrende Ausgaben", "repeat", "/settings/recurring"},
    {"rates", "Wechselkurse", "banknote", "/settings/rates"},
    {"ynab", "YNAB", "wallet", "/settings/ynab"},
    {"export", "Export", "archive", "/export"}
  ]

  @impl true
  def mount(_params, _session, socket) do
    {:ok,
     socket
     |> assign(page_title: Layouts.page_title("Einstellungen"), links: @links)
     |> assign_form(Settings.change_settings(Settings.get_settings()))}
  end

  @impl true
  def handle_event("validate", %{"settings" => params}, socket) do
    changeset = Settings.change_settings(Settings.get_settings(), params)
    {:noreply, assign_form(socket, Map.put(changeset, :action, :validate))}
  end

  def handle_event("save", %{"settings" => params}, socket) do
    case Settings.update_settings(socket.assigns.current_participant.id, params) do
      {:ok, setting} ->
        {:noreply,
         socket
         |> assign(page_title: Layouts.page_title("Einstellungen"))
         |> assign_form(Settings.change_settings(setting))
         |> push_saved("settings-save")}

      {:error, changeset} ->
        {:noreply, assign_form(socket, changeset)}
    end
  end

  defp assign_form(socket, changeset), do: assign(socket, form: to_form(changeset, as: :settings))

  @impl true
  def render(assigns) do
    ~H"""
    <Layouts.app flash={@flash} current={:settings} participant={@current_participant}>
      <.header>
        Einstellungen
        <:subtitle>Gruppe, Personen, Kategorien und mehr.</:subtitle>
      </.header>

      <div class="flex flex-col gap-8">
        <section aria-labelledby="settings-group">
          <.section_heading id="settings-group">Gruppe</.section_heading>
          <.form for={@form} id="settings-form" phx-change="validate" phx-submit="save">
            <.input
              field={@form[:group_name]}
              label="Name der Gruppe"
              required
              maxlength={Zipfelkasse.Names.max_length()}
              autocomplete="off"
              inline
            >
              <.button
                id="settings-save"
                type="submit"
                variant={:primary}
                saved
                phx-disable-with="Speichert …"
                class="join-item"
              >
                Speichern
              </.button>
            </.input>
          </.form>
        </section>

        <section aria-labelledby="settings-appearance">
          <.section_heading id="settings-appearance">Darstellung</.section_heading>
          <p class="mb-3 text-sm text-base-content/70">Gilt nur für dieses Gerät.</p>
          <.theme_toggle id="settings-theme" />
        </section>

        <nav aria-label="Weitere Einstellungen">
          <.list id="settings-links">
            <.list_row
              :for={{key, label, plush, path} <- @links}
              id={"settings-link-#{key}"}
              title={label}
              navigate={path}
            >
              <:leading><.plush name={plush} size={:lg} /></:leading>
            </.list_row>
          </.list>
        </nav>
      </div>
    </Layouts.app>
    """
  end
end
