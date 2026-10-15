defmodule ZipfelkasseWeb.HealthController do
  @moduledoc false
  use ZipfelkasseWeb, :controller

  require Logger

  def show(conn, _params) do
    case Zipfelkasse.Repo.query("SELECT 1") do
      {:ok, _result} ->
        json(conn, %{status: "up"})

      {:error, error} ->
        Logger.error("Health check failed: " <> Exception.message(error))

        conn
        |> put_status(:service_unavailable)
        |> json(%{status: "down"})
    end
  end
end
