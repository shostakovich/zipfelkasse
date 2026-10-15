defmodule Zipfelkasse.StatisticsTest do
  use Zipfelkasse.DataCase

  import Zipfelkasse.Fixtures

  alias Zipfelkasse.{Expenses, Statistics}

  test "counts the expenses the expense search finds" do
    h = household()
    both = [h.anna, h.ben]

    create!(equal(h, "Bäckerei Ölmühle", 500, "2026-09-01", h.anna, both))

    h
    |> equal("Brot", 300, "2026-09-02", h.ben, both)
    |> Map.merge(%{category_id: nil, notes: "BÄCKEREI"})
    |> create!()

    create!(equal(h, "Kino", 1200, "2026-09-03", h.anna, both))
    create!(equal(h, "Bäckerei", 400, "2026-08-01", h.anna, both))

    for filters <- [
          [text: [" bäckerei "]],
          [text: ["kino", "BROT"], from: ~D[2026-09-01]],
          [text: ["bäckerei"], to: ~D[2026-08-31]],
          [without_category: true],
          [category_id: h.food, from: ~D[2026-09-02]]
        ] do
      found = Expenses.list_expenses(filters)
      [total] = Statistics.rows(Map.new([group_by: :year] ++ filters))

      assert {total.count, total.amount_cents} ==
               {length(found), found |> Enum.map(& &1.amount_cents) |> Enum.sum()},
             inspect(filters)
    end
  end
end
