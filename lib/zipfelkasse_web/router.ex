defmodule ZipfelkasseWeb.Router do
  use ZipfelkasseWeb, :router

  pipeline :browser do
    plug :accepts, ["html"]
    plug :fetch_session
    plug :fetch_live_flash
    plug :put_root_layout, html: {ZipfelkasseWeb.Layouts, :root}
    plug :protect_from_forgery
  end

  pipeline :participant do
    plug ZipfelkasseWeb.CurrentParticipant
  end

  scope "/", ZipfelkasseWeb do
    get "/up", HealthController, :show
    get "/manifest.webmanifest", PwaController, :manifest
    get "/sw.js", PwaController, :service_worker
    get "/favicon.ico", PwaController, :favicon
    forward "/mcp", MCPPlug, [], log: false
  end

  scope "/", ZipfelkasseWeb do
    pipe_through :browser

    get "/who", WhoController, :show
    post "/who", WhoController, :choose
    post "/who/new", WhoController, :create
  end

  scope "/", ZipfelkasseWeb do
    pipe_through [:browser, :participant]

    live_session :default, on_mount: ZipfelkasseWeb.CurrentParticipant do
      live "/", ExpensesLive
      live "/expenses/new", ExpenseLive, :new
      live "/expenses/:id", ExpenseLive, :edit
      live "/balances", BalancesLive
      live "/activity", ActivityLive
      live "/settings", SettingsLive
      live "/settings/participants", ParticipantsLive
      live "/settings/categories", CategoriesLive
      live "/settings/recurring", RecurringLive
      live "/settings/recurring/new", RecurringNewLive
      live "/settings/rates", RatesLive
      live "/settings/ynab", YnabLive
      live "/export", ExportLive
    end

    get "/export/expenses.csv", ExportController, :expenses_csv
    get "/export/expenses.json", ExportController, :expenses_json
    get "/export/ynab.ofx", ExportController, :ynab_ofx
    get "/export/ynab.csv", ExportController, :ynab_csv
  end
end
