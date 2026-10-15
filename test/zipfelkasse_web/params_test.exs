defmodule ZipfelkasseWeb.ParamsTest do
  use ExUnit.Case, async: true

  alias ZipfelkasseWeb.Params

  test "reads a positive integer and nothing else" do
    assert Params.positive_integer("42") == 42

    for text <- ["0", "-1", "1.5", "4 2", "", "abc", nil, 7] do
      assert Params.positive_integer(text) == nil
    end
  end
end
