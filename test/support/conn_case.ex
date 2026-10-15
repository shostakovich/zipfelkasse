defmodule ZipfelkasseWeb.ConnCase do
  @moduledoc """
  Test case for tests that build a connection; database changes are rolled back via the sandbox.
  """

  use ExUnit.CaseTemplate

  using do
    quote do
      @endpoint ZipfelkasseWeb.Endpoint

      use ZipfelkasseWeb, :verified_routes

      import Plug.Conn
      import Phoenix.ConnTest
    end
  end

  setup tags do
    Zipfelkasse.DataCase.setup_sandbox(tags)
    {:ok, conn: Phoenix.ConnTest.build_conn()}
  end
end
