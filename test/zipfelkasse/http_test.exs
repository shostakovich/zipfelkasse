defmodule Zipfelkasse.HTTPTest do
  use ExUnit.Case, async: true

  alias Zipfelkasse.HTTP

  defmodule Stub do
    @behaviour Plug

    import Plug.Conn

    @impl true
    def init(opts), do: opts

    @impl true
    def call(conn, {:redirect, to}),
      do: conn |> put_resp_header("location", to) |> send_resp(302, "")

    def call(conn, {:sleep, ms}) do
      Process.sleep(ms)
      send_resp(conn, 200, "late")
    end

    def call(conn, {:body, body}), do: send_resp(conn, 200, body)

    def call(conn, {:chunks, chunks}) do
      conn = send_chunked(conn, 200)

      Enum.reduce(chunks, conn, fn chunk, conn ->
        {:ok, conn} = chunk(conn, chunk)
        conn
      end)
    end

    def call(conn, {:status, status}), do: send_resp(conn, status, "nope")

    def call(conn, {:echo, test}) do
      {:ok, body, conn} = read_body(conn)
      send(test, {:request, conn.method, conn.req_headers, body})
      conn |> put_resp_header("retry-after", "60") |> send_resp(201, "echoed")
    end

    def call(conn, {:record, test}) do
      send(test, {:request, conn.method, conn.req_headers})
      send_resp(conn, 200, "recorded")
    end
  end

  defp serve(opts) do
    server = {Bandit, plug: {Stub, opts}, ip: :loopback, port: 0, startup_log: false}
    pid = start_supervised!(server, id: make_ref())
    {:ok, {_ip, port}} = ThousandIsland.listener_info(pid)
    "http://127.0.0.1:#{port}/"
  end

  test "gets the status and body with the given headers" do
    assert HTTP.get(serve({:record, self()}), [{"user-agent", "zipfelkasse/1.0"}]) ==
             {:ok, 200, "recorded"}

    assert_received {:request, "GET", headers}
    assert {"user-agent", "zipfelkasse/1.0"} in headers
    assert HTTP.get(serve({:status, 503})) == {:ok, 503, "nope"}
  end

  test "does not follow a redirect" do
    url = serve({:redirect, serve({:record, self()})})

    assert {:ok, 302, _body} = HTTP.get(url)
    refute_received {:request, _method, _headers}
  end

  test "stops reading a body larger than the cap" do
    assert HTTP.get(serve({:body, String.duplicate("x", 100)}), [], max_body: 100) ==
             {:ok, 200, String.duplicate("x", 100)}

    assert HTTP.get(serve({:body, String.duplicate("x", 101)}), [], max_body: 100) ==
             {:error, :too_large}

    assert HTTP.get(serve({:chunks, List.duplicate(String.duplicate("x", 60), 3)}), [],
             max_body: 100
           ) ==
             {:error, :too_large}
  end

  test "tells a response that does not come in time from no response at all" do
    assert HTTP.get(serve({:sleep, 500}), [], timeout: 50) == {:error, :timeout}
    assert {:error, {:failed_connect, _details}} = HTTP.get("http://127.0.0.1:1/")
  end

  test "sends other methods with a JSON body and returns the response headers" do
    url = serve({:echo, self()})

    assert {:ok, 201, headers, "echoed"} =
             HTTP.request(:post, url, [{"authorization", "Bearer t"}], %{transactions: [1]})

    assert {"retry-after", "60"} in headers
    assert_received {:request, "POST", request_headers, ~s({"transactions":[1]})}
    assert {"authorization", "Bearer t"} in request_headers
    assert {"content-type", "application/json"} in request_headers

    assert {:ok, 201, _headers, "echoed"} = HTTP.request(:patch, url, [], [])
    assert_received {:request, "PATCH", _headers, "[]"}
    assert {:ok, 201, _headers, "echoed"} = HTTP.request(:delete, url, [])
    assert_received {:request, "DELETE", _headers, ""}
  end
end
