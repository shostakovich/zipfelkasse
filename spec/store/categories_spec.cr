require "../spec_helper"

private def category_names(store : Store) : Array(String)
  store.list_categories.map(&.name)
end

describe "Store categories" do
  use_household

  it "puts a new category before Sonstiges" do
    id = store.create_category(nil, "Haustiere")

    categories = store.list_categories
    {categories[-1].name, categories[-2].id}.should eq({"Sonstiges", id})
  end

  it "refuses the name of an existing category, regardless of its case" do
    expect_invalid("Die Kategorie „lebensmittel“ gibt es schon.") { store.create_category(nil, "lebensmittel") }
  end

  it "renames and archives a category" do
    id = store.create_category(nil, "Haustiere")
    store.rename_category(nil, id, "Tiere")
    store.set_category_archived(nil, id, true)

    category = store.get_category(id)
    {category.name, category.archived?}.should eq({"Tiere", true})
  end

  describe "moving a category" do
    it "swaps it with its neighbour" do
      first, second = store.list_categories

      store.move_category(nil, second.id, true)
      category_names(store)[0, 2].should eq [second.name, first.name]
      store.move_category(nil, second.id, false)
      category_names(store)[0, 2].should eq [first.name, second.name]
    end

    it "does nothing at the edge" do
      first = store.list_categories.first

      store.move_category(nil, first.id, true)

      category_names(store).first.should eq first.name
    end

    it "does not know an archived or unknown category" do
      second = store.list_categories[1]
      store.set_category_archived(nil, second.id, true)

      expect_raises(Store::NotFound) { store.move_category(nil, second.id, true) }
      expect_raises(Store::NotFound) { store.move_category(nil, 999_i64, true) }
    end
  end

  describe "creating a category after moves renumbered the positions" do
    it "puts it directly before Sonstiges" do
      store.move_category(nil, store.list_categories[0].id, false)

      store.create_category(nil, "Neu")

      category_names(store).last(3).should eq ["Geschenke", "Neu", "Sonstiges"]
    end

    it "still puts it directly before Sonstiges when that moved up by one" do
      store.create_category(nil, "Neu")
      store.move_category(nil, store.list_categories.last.id, true)

      store.create_category(nil, "Noch neuer")

      category_names(store).last(4).should eq ["Geschenke", "Noch neuer", "Sonstiges", "Neu"]
    end

    it "puts it at the end without an active Sonstiges" do
      store.set_category_archived(nil, store.list_categories.last.id, true)

      store.create_category(nil, "Zuletzt")

      category_names(store).last.should eq "Zuletzt"
    end
  end

  it "counts the live expenses of a category" do
    h = household
    h.create(h.equal("A", 1000, "2026-09-30", h.anna, h.anna))
    deleted = h.create(h.equal("B", 1000, "2026-09-30", h.anna, h.anna))
    h.create(h.equal("C", 1000, "2026-09-30", h.anna, h.anna))
    store.delete_expense(h.anna, deleted)

    store.expense_count_by_category.should eq({h.food => 2})
  end

  it "lists the category history" do
    h = household
    cats = store.list_categories
    other, archived = cats[1].id, cats[2].id
    mk = ->(title : String, d : String, cat : Int64?) do
      input = h.equal(title, 1000, d, h.anna, h.anna, h.ben)
      input.category_id = cat
      h.create(input)
    end
    mk.call("Kaufland", "2026-09-01", h.food)
    mk.call("Kino", "2026-09-10", other)
    mk.call("Ohne", "2026-09-11", nil)
    mk.call("Archiviert", "2026-09-12", archived)
    gone = mk.call("Gelöscht", "2026-09-13", h.food)
    store.delete_expense(h.anna, gone)
    store.set_category_archived(nil, archived, true)
    back = h.equal("Rückzahlung", 500, "2026-09-14", h.ben, h.anna)
    back.reimbursement = true
    store.create_expense(h.ben, back)

    store.category_history.should eq [Store::TitleCategory.new("Kino", other), Store::TitleCategory.new("Kaufland", h.food)]
  end
end
