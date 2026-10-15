defmodule ZipfelkasseWeb.Layouts do
  @moduledoc false
  use ZipfelkasseWeb, :html

  alias Zipfelkasse.Settings

  embed_templates "layouts/*"

  attr :flash, :map, required: true

  attr :current, :atom,
    default: nil,
    doc: "the open section: `:expenses`, `:balances`, `:activity` or `:settings`"

  attr :participant, :any, default: nil, doc: "the person using the app; nil shows only the brand"
  attr :fab, :boolean, default: true, doc: "false on forms, whose action bar is the main action"

  slot :inner_block, required: true

  @doc """
  Pages in Setzkasten's top-bar shell: the four sections (the dock on phones), who is using the
  app and „Ausgabe hinzufügen“ as the phone's floating button (not on forms). Without a person,
  as on /who for a first visit, only the brand shows.
  """
  def app(assigns) do
    ~H"""
    <.app_shell layout={:topbar} width={:narrow} bar_width={:default} current={@current}>
      <:brand>
        <.link navigate={~p"/"} class="flex min-w-0 items-center gap-2">
          <.plush
            src={~p"/images/brand/mascot-light.webp"}
            dark_src={~p"/images/brand/mascot-dark.webp"}
            size={:lg}
          />
          <span class="truncate">Zipfelkasse</span>
        </.link>
      </:brand>
      <:nav
        :if={@participant}
        key={:expenses}
        label="Ausgaben"
        plush="receipt"
        icon="receipt"
        navigate={~p"/"}
      />
      <:nav
        :if={@participant}
        key={:balances}
        label="Salden"
        plush="scale"
        icon="scale"
        navigate={~p"/balances"}
      />
      <:nav
        :if={@participant}
        key={:activity}
        label="Aktivität"
        plush="activity"
        icon="activity"
        navigate={~p"/activity"}
      />
      <:nav
        :if={@participant}
        key={:settings}
        label="Einstellungen"
        plush="settings"
        icon="settings"
        navigate={~p"/settings"}
      />
      <:account :if={@participant}>
        <p class="flex min-w-0 max-w-44 items-baseline gap-1 text-sm text-base-content/70 sm:max-w-xs">
          <span class="shrink-0">Du bist</span>
          <strong id="current-participant" class="truncate font-semibold text-base-content">
            {@participant.name}
          </strong>
        </p>
        <.button href={~p"/who"} variant={:ghost} size={:sm} class="-ms-1">wechseln</.button>
      </:account>
      <:fab :if={@participant && @fab}>
        <.fab navigate={~p"/expenses/new"} label="Ausgabe hinzufügen" />
      </:fab>
      {render_slot(@inner_block)}
    </.app_shell>

    <.flash_group flash={@flash} />
    <.confirm_dialog />
    """
  end

  @doc """
  A page's title with the group's name; pages assign it whole as `page_title`, since the root
  layout renders only once and a suffix there would keep an old group name.
  """
  def page_title(page), do: page <> " · " <> group_name()

  @doc "The group's name; the default while the database is unreachable."
  def group_name do
    Settings.group_name()
  rescue
    _error in [DBConnection.ConnectionError, Exqlite.Error] -> "Zipfelkasse"
  end
end
