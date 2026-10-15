defmodule ZipfelkasseWeb.HealthControllerTest do
  use ZipfelkasseWeb.ConnCase

  import ExUnit.CaptureLog

  test "GET /up reports the database as up", %{conn: conn} do
    assert conn |> get(~p"/up") |> json_response(200) == %{"status" => "up"}
  end

  test "GET /up answers 503 when the database cannot be reached and logs why", %{conn: conn} do
    # A second repo below a regular file cannot connect; its errors are logged asynchronously.
    log =
      capture_log(fn ->
        repo =
          start_supervised!({
            Zipfelkasse.Repo,
            name: nil,
            database: "/dev/null/zipfelkasse.sqlite3",
            pool: DBConnection.ConnectionPool,
            pool_size: 1,
            queue_target: 10,
            queue_interval: 10
          })

        Zipfelkasse.Repo.put_dynamic_repo(repo)

        assert conn |> get(~p"/up") |> json_response(503) == %{"status" => "down"}

        Zipfelkasse.Repo.put_dynamic_repo(Zipfelkasse.Repo)
        stop_supervised!(Zipfelkasse.Repo)
      end)

    assert log =~ ~r/\[error\] Health check failed: .*connection not available/
  end

  # Changes the global log level, so the module stays synchronous.
  test "health checks stay out of the request log", %{conn: conn} do
    level = Logger.level()
    Logger.configure(level: :info)
    on_exit(fn -> Logger.configure(level: level) end)

    refute capture_log(fn -> get(conn, ~p"/up") end) =~ "GET /up"
    assert capture_log(fn -> get(build_conn(), ~p"/") end) =~ "GET /"
  end
end
