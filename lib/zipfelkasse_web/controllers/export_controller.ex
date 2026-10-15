defmodule ZipfelkasseWeb.ExportController do
  @moduledoc false
  use ZipfelkasseWeb, :controller

  alias Zipfelkasse.Exports

  def expenses_csv(conn, params), do: download(conn, params, &Exports.expenses_csv/1)
  def expenses_json(conn, params), do: download(conn, params, &Exports.expenses_json/1)

  def ynab_ofx(conn, params),
    do: download(conn, params, &Exports.ynab_ofx(conn.assigns.current_participant, &1))

  def ynab_csv(conn, params),
    do: download(conn, params, &Exports.ynab_csv(conn.assigns.current_participant, &1))

  defp download(conn, params, export) do
    case Exports.period(params) do
      {:ok, period} ->
        file = export.(period)

        conn
        |> put_resp_header("content-type", file.content_type)
        |> put_resp_header("content-disposition", ~s(attachment; filename="#{file.filename}"))
        |> put_resp_header("cache-control", "no-store")
        |> send_resp(200, file.body)

      {:error, _message} ->
        query = for key <- ~w(from to), is_binary(params[key]), do: {key, params[key]}
        conn |> put_status(:see_other) |> redirect(to: ~p"/export?#{query}")
    end
  end
end
