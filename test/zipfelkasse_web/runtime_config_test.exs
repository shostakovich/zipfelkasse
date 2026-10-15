defmodule ZipfelkasseWeb.RuntimeConfigTest do
  # Sets environment variables, so it cannot run alongside other tests.
  use ExUnit.Case, async: false

  alias Zipfelkasse.Network

  @required %{
    "DATABASE_PATH" => "/srv/kasse/zipfelkasse.sqlite3",
    "PHX_HOST" => "kasse.example.org",
    "SECRET_KEY_BASE" => String.duplicate("a", 64)
  }
  @optional ~w(PORT MCP_SECRET MCP_ALLOWED_CIDRS TRUSTED_PROXIES)

  setup do
    names = Map.keys(@required) ++ @optional
    previous = Map.new(names, &{&1, System.get_env(&1)})
    Enum.each(@optional, &System.delete_env/1)
    System.put_env(@required)

    on_exit(fn ->
      Enum.each(previous, fn
        {name, nil} -> System.delete_env(name)
        {name, value} -> System.put_env(name, value)
      end)
    end)
  end

  defp prod, do: Config.Reader.read!("config/runtime.exs", env: :prod)[:zipfelkasse]

  defp networks(text) do
    {:ok, networks} = Network.parse_list(text)
    networks
  end

  test "production runs on the given database and host" do
    config = prod()
    endpoint = config[ZipfelkasseWeb.Endpoint]

    assert config[Zipfelkasse.Repo][:database] == "/srv/kasse/zipfelkasse.sqlite3"
    assert config[:backup_dir] == "/srv/kasse/backups"
    assert endpoint[:url] == [host: "kasse.example.org", port: 443, scheme: "https"]
    assert endpoint[:http] == [ip: {0, 0, 0, 0}, port: 4000]
    assert endpoint[:check_origin] == ["//kasse.example.org"]
    assert endpoint[:secret_key_base] == String.duplicate("a", 64)
  end

  test "MCP is off and allows Anthropic's range by default, behind no trusted proxy" do
    assert prod()[:mcp] == [
             secret: nil,
             allowed_cidrs: networks("160.79.104.0/21"),
             trusted_proxies: []
           ]
  end

  test "reads the optional variables, trimmed" do
    System.put_env(%{
      "PORT" => " 4100 ",
      "MCP_SECRET" => " s3cret ",
      "MCP_ALLOWED_CIDRS" => "10.0.0.0/8, 192.168.1.5",
      "TRUSTED_PROXIES" => "172.18.0.2 fd00::/8"
    })

    config = prod()

    assert config[ZipfelkasseWeb.Endpoint][:http][:port] == 4100

    assert config[:mcp] == [
             secret: "s3cret",
             allowed_cidrs: networks("10.0.0.0/8 192.168.1.5"),
             trusted_proxies: networks("172.18.0.2, fd00::/8")
           ]
  end

  test "an empty value counts as unset" do
    System.put_env(%{"MCP_SECRET" => " ", "MCP_ALLOWED_CIDRS" => "", "PORT" => ""})

    config = prod()

    assert config[:mcp][:secret] == nil
    assert config[:mcp][:allowed_cidrs] == networks("160.79.104.0/21")
    assert config[ZipfelkasseWeb.Endpoint][:http][:port] == 4000
  end

  for name <- ~w(DATABASE_PATH PHX_HOST SECRET_KEY_BASE) do
    test "production refuses to start without #{name}" do
      System.put_env(unquote(name), " ")

      assert_raise RuntimeError, ~r/environment variable #{unquote(name)} is missing/, &prod/0
    end
  end

  for {name, value, message} <- [
        {"MCP_ALLOWED_CIDRS", "10.0.0.0/33",
         ~s(invalid MCP_ALLOWED_CIDRS: "33" is not a valid prefix length for 10.0.0.0)},
        {"TRUSTED_PROXIES", "10.0.0.1 garbage",
         ~s(invalid TRUSTED_PROXIES: "garbage" is not an IP address or network)},
        {"PORT", "80a", ~s(invalid PORT: "80a" is not a port number)},
        {"PORT", "70000", ~s(invalid PORT: "70000" is not a port number)}
      ] do
    test "refuses #{name}=#{value}, naming the variable" do
      System.put_env(unquote(name), unquote(value))

      assert_raise RuntimeError, unquote(message), &prod/0
    end
  end

  test "tests ignore the environment" do
    System.put_env(%{"MCP_SECRET" => "s3cret", "MCP_ALLOWED_CIDRS" => "garbage", "PORT" => "1"})

    config = Config.Reader.read!("config/runtime.exs", env: :test)[:zipfelkasse]

    assert config[:mcp][:secret] == nil
    refute config[ZipfelkasseWeb.Endpoint]
  end
end
