defmodule Zipfelkasse.DevConfigTest do
  # Sets environment variables, so it cannot run alongside other tests.
  use ExUnit.Case, async: false

  @names ~w(DATABASE_PATH YNAB_BASE_URL)

  setup do
    previous = Map.new(@names, &{&1, System.get_env(&1)})
    Enum.each(@names, &System.delete_env/1)

    on_exit(fn ->
      Enum.each(previous, fn
        {name, nil} -> System.delete_env(name)
        {name, value} -> System.put_env(name, value)
      end)
    end)
  end

  defp ynab_url do
    config = Config.Reader.read!("config/dev.exs", env: :dev)[:zipfelkasse]
    config[Zipfelkasse.Ynab.Client][:base_url]
  end

  test "a copy of other data never reaches YNAB unless an address is given" do
    assert ynab_url() == nil

    System.put_env("DATABASE_PATH", "/tmp/copy.sqlite3")
    assert ynab_url() == "http://127.0.0.1:9"

    System.put_env("YNAB_BASE_URL", "http://localhost:9999/v1")
    assert ynab_url() == "http://localhost:9999/v1"
  end
end
