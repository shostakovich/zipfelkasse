defmodule Zipfelkasse.Application do
  @moduledoc false

  use Application

  @impl true
  def start(_type, _args) do
    children =
      [
        Zipfelkasse.Repo,
        {Phoenix.PubSub, name: Zipfelkasse.PubSub},
        Zipfelkasse.Fx.Loader,
        Zipfelkasse.Ynab.Cache,
        ZipfelkasseWeb.Endpoint
      ] ++ jobs()

    Supervisor.start_link(children, strategy: :one_for_one, name: Zipfelkasse.Supervisor)
  end

  defp jobs do
    if Application.fetch_env!(:zipfelkasse, :jobs),
      do: [
        Zipfelkasse.Fx.RefreshJob,
        Zipfelkasse.Recurring.Job,
        Zipfelkasse.Backup.Job,
        Zipfelkasse.Ynab.Scheduler
      ],
      else: []
  end

  @impl true
  def config_change(changed, _new, removed) do
    ZipfelkasseWeb.Endpoint.config_change(changed, removed)
    :ok
  end
end
