defmodule Zipfelkasse.FakeEcb do
  @moduledoc """
  The ECB's rate files for tests, served by Bandit on a free port: deterministic rates of a
  few currencies for every business day from 2023-12-01 up to `last_day`, newest first.

  `put/3` sets `:last_day` or `:failure`, which answers every request with that HTTP status,
  with `:empty` (a valid file without rates) or with `:broken` (a cut-off file). `block/1` holds
  the requests until `release/1`.
  """

  @behaviour Plug

  import Plug.Conn

  @currencies [
    {"USD", 1.0912},
    {"JPY", 158.37},
    {"CZK", 24.871},
    {"DKK", 7.4586},
    {"GBP", 0.85412},
    {"HUF", 389.65},
    {"PLN", 4.3155},
    {"SEK", 11.2635},
    {"CHF", 0.94315},
    {"IDR", 17_342.81}
  ]
  @first_day ~D[2023-12-01]
  @holidays [
    ~D[2024-03-29],
    ~D[2024-04-01],
    ~D[2025-04-18],
    ~D[2025-04-21],
    ~D[2026-04-03],
    ~D[2026-04-06]
  ]

  @doc "Serves the files for the running test; gives the fake with its `url`."
  def start(last_day \\ ~D[2026-10-02]) do
    state =
      ExUnit.Callbacks.start_supervised!(
        {Agent, fn -> %{last_day: last_day, failure: nil, blocked: false, requests: []} end},
        id: make_ref()
      )

    server =
      ExUnit.Callbacks.start_supervised!(
        {Bandit, plug: {__MODULE__, state}, ip: :loopback, port: 0, startup_log: false},
        id: make_ref()
      )

    {:ok, {_ip, port}} = ThousandIsland.listener_info(server)
    %{state: state, url: "http://127.0.0.1:#{port}/"}
  end

  def put(fake, key, value), do: Agent.update(fake.state, &Map.put(&1, key, value))

  @doc "The requested files and user agents, the first first."
  def requests(fake), do: Agent.get(fake.state, &Enum.reverse(&1.requests))

  def block(fake), do: put(fake, :blocked, true)
  def release(fake), do: put(fake, :blocked, false)

  def currencies, do: Enum.map(@currencies, &elem(&1, 0))

  @doc "The rate of a currency on a day as the file has it."
  def rate(currency, day) do
    {_currency, base} = List.keyfind(@currencies, currency, 0)
    n = Date.diff(day, @first_day)
    code = currency |> String.to_charlist() |> Enum.sum()
    wobble = 1 + 0.03 * :math.sin(n / 17 + code) + 0.0004 * rem(n, 7)

    digits =
      cond do
        base >= 1000 -> 2
        base >= 100 -> 3
        base >= 10 -> 4
        true -> 5
      end

    :erlang.float_to_binary(base * wobble, decimals: digits)
  end

  def rate!(currency, day), do: String.to_float(rate(currency, day))

  @doc "The 90-day file or the whole history up to `last_day`."
  def file("eurofxref-hist-90d.xml", last_day),
    do: xml(Enum.filter(days(last_day), &(Date.diff(last_day, &1) < 90)))

  def file("eurofxref-hist.xml", last_day), do: xml(days(last_day))

  def business_day?(day) do
    Date.day_of_week(day) in 1..5 and
      {day.month, day.day} not in [{1, 1}, {5, 1}, {12, 25}, {12, 26}] and
      day not in @holidays
  end

  defp days(last_day) do
    last_day |> Date.range(@first_day, -1) |> Enum.filter(&business_day?/1)
  end

  defp xml(days) do
    cubes =
      for day <- days do
        rates =
          for {currency, _base} <- @currencies do
            "\t\t\t<Cube currency='#{currency}' rate='#{rate(currency, day)}'/>\n"
          end

        ["\t\t<Cube time='#{day}'>\n", rates, "\t\t</Cube>\n"]
      end

    IO.iodata_to_binary([
      ~s(<?xml version="1.0" encoding="UTF-8"?>\n),
      ~s(<gesmes:Envelope xmlns:gesmes="http://www.gesmes.org/xml/2002-08-01" ),
      ~s(xmlns="http://www.ecb.int/vocabulary/2002-08-01/eurofxref">\n),
      "\t<gesmes:subject>Reference rates</gesmes:subject>\n",
      "\t<gesmes:Sender>\n\t\t<gesmes:name>European Central Bank</gesmes:name>\n\t</gesmes:Sender>\n",
      "\t<Cube>\n",
      cubes,
      "\t</Cube>\n</gesmes:Envelope>\n"
    ])
  end

  @impl true
  def init(state), do: state

  @impl true
  def call(conn, state) do
    file = Enum.join(conn.path_info, "/")

    Agent.update(state, fn s ->
      %{s | requests: [{file, get_req_header(conn, "user-agent")} | s.requests]}
    end)

    wait_while_blocked(state)
    %{failure: failure, last_day: last_day} = Agent.get(state, & &1)
    conn = put_resp_content_type(conn, "text/xml")

    case failure do
      status when is_integer(status) ->
        send_resp(conn, status, "broken")

      :empty ->
        send_resp(conn, 200, xml([]))

      :broken ->
        send_resp(conn, 200, "<broken")

      nil when file in ["eurofxref-hist-90d.xml", "eurofxref-hist.xml"] ->
        send_resp(conn, 200, file(file, last_day))

      nil ->
        send_resp(conn, 404, "")
    end
  end

  defp wait_while_blocked(state) do
    if Agent.get(state, & &1.blocked) do
      Process.sleep(10)
      wait_while_blocked(state)
    end
  end
end
