defmodule Zipfelkasse.OrderedJSONTest do
  use ExUnit.Case, async: true

  alias Zipfelkasse.OrderedJSON

  @term [b: 1, a: [z: nil, y: "ä"], list: [[q: 1], [], %{m: 2, k: 1}], empty: []]

  test "keyword lists keep their order, maps and lists encode as usual" do
    assert OrderedJSON.encode!(@term) ==
             ~s({"b":1,"a":{"z":null,"y":"ä"},"list":[{"q":1},[],{"k":1,"m":2}],"empty":[]})
  end

  test "the formatted JSON is indented by two spaces and ends with a newline" do
    assert OrderedJSON.format!(b: 1, a: [z: nil, y: [1, 2]], empty: []) == """
           {
             "b": 1,
             "a": {
               "z": null,
               "y": [1,2]
             },
             "empty": []
           }
           """
  end
end
