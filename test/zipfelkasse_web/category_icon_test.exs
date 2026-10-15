defmodule ZipfelkasseWeb.CategoryIconTest do
  use ExUnit.Case, async: true

  alias Zipfelkasse.Categories.Category
  alias Zipfelkasse.Expenses.Expense
  alias ZipfelkasseWeb.CategoryIcon

  for {name, plush} <- [
        {"Lebensmittel", "shopping-cart"},
        {"Restaurant", "utensils"},
        {"Haushalt", "house"},
        {"Miete & Nebenkosten", "key"},
        {"Nebenkosten", "zap"},
        {"Transport", "car"},
        {"ÖPNV", "car"},
        {"Reisen", "plane"},
        {"Freizeit", "ticket"},
        {"Gesundheit", "heart"},
        {"Geschenke", "gift"},
        {"Kleidung", "shirt"},
        {"Kita", "baby"},
        {"Haustier", "paw-print"},
        {"Bücher", "graduation-cap"},
        {"Streaming-Abos", "smartphone"},
        {"Versicherungen", "shield"},
        {"Sonstiges", "receipt"},
        {"Kunst", "tag"},
        {nil, "tag"}
      ] do
    test "#{inspect(name)} shows #{plush}" do
      assert CategoryIcon.for_category(unquote(name)) == unquote(plush)
      assert unquote(plush) in ZipfelkasseWeb.Plush.names()
    end
  end

  test "every plush is an image of its own, the same in both themes" do
    dir = Application.app_dir(:zipfelkasse, "priv/static/images/plush")

    for name <- ZipfelkasseWeb.Plush.names() do
      assert File.exists?(Path.join(dir, name <> ".webp")), name
    end

    assert ZipfelkasseWeb.Plush.src("receipt", :light) =~ ~r"^/images/plush/receipt"
    assert ZipfelkasseWeb.Plush.src("receipt", :dark) == nil
    assert ZipfelkasseWeb.Plush.src("nope", :light) == nil
  end

  test "an expense shows its category, a reimbursement banknotes" do
    assert CategoryIcon.for_expense(%Expense{category: %Category{name: "Reisen"}}) == "plane"
    assert CategoryIcon.for_expense(%Expense{category: nil}) == "tag"
    assert CategoryIcon.for_expense(%Expense{reimbursement: true, category: nil}) == "banknote"
  end
end
