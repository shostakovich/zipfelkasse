require "../spec_helper"

describe "Store participants" do
  use_store

  it "creates a participant with a normalized name" do
    id = store.create_participant(nil, "  Anna  ")

    participant = store.get_participant(id)
    {participant.name, participant.archived?}.should eq({"Anna", false})
    participant.created_at.should_not be_nil
  end

  it "refuses an empty name and a name that exists, regardless of its case" do
    store.create_participant(nil, "Anna")

    expect_invalid("Bitte einen Namen für die Person angeben.") { store.create_participant(nil, "   ") }
    expect_invalid("„anna“ gibt es schon.") { store.create_participant(nil, "anna") }
  end

  it "renames a participant, but not to the name of another" do
    store.create_participant(nil, "Anna")
    ben = store.create_participant(nil, "Ben")

    store.rename_participant(nil, ben, "Benedikt")
    store.get_participant(ben).name.should eq "Benedikt"
    expect_invalid("„ANNA“ gibt es schon.") { store.rename_participant(nil, ben, "ANNA") }
  end

  it "lists archived participants only on request and restores them" do
    store.create_participant(nil, "Anna")
    ben = store.create_participant(nil, "Ben")
    store.set_participant_archived(nil, ben, true)

    store.list_participants.size.should eq 1
    store.list_participants(true).map(&.archived?).should eq [false, true]

    store.set_participant_archived(nil, ben, false)
    store.list_participants.size.should eq 2
  end

  it "does not know a participant that was never created" do
    expect_raises(Store::NotFound) { store.get_participant(999_i64) }
    expect_raises(Store::NotFound) { store.rename_participant(nil, 999_i64, "X") }
  end
end

describe "Store participants with expenses" do
  use_household

  # Deleted expenses do not count.
  it "archives a person only without a balance" do
    h = household
    id = h.create(h.equal("Einkauf", 1000, "2026-08-01", h.anna, h.anna, h.ben))
    expect_raises(Domain::ValidationError, "Ben hat noch einen Saldo von -5,00 €") { store.set_participant_archived(nil, h.ben, true) }
    store.get_participant(h.ben).archived?.should be_false
    store.set_participant_archived(nil, h.cleo, true)
    expect_raises(Store::NotFound) { store.set_participant_archived(nil, 999_i64, true) }
    store.delete_expense(h.anna, id)
    store.set_participant_archived(nil, h.ben, true)
  end

  it "counts the live expenses a person paid or shares" do
    h = household
    h.create(h.equal("A", 1000, "2026-09-30", h.anna, h.anna, h.ben))
    deleted = h.create(h.equal("B", 1000, "2026-09-30", h.ben, h.ben))
    h.create(h.equal("C", 1000, "2026-09-30", h.cleo, h.ben))
    store.delete_expense(h.anna, deleted)

    store.expense_count_by_participant.should eq({h.anna => 1, h.ben => 2, h.cleo => 1})
  end
end
