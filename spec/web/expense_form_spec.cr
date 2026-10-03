require "../spec_helper"

describe "The expense form" do
  use_household

  # Even if the ECB rate known today differs (e.g. published only later), saving
  # an expense with its currency, date and rate unchanged keeps the saved rate.
  it "keeps the saved ECB rate when an expense is saved unchanged" do
    id = household.create(household.foreign("Einkauf USA", 1080, "USD", 1.08, "2026-09-30", household.anna, household.anna))
    server = TestServer.new(Config.new, store)
    server.app.deps.fx = FakeFX.new(server.app.deps, {"USD" => 1.2})
    form = {
      "titel" => "Einkauf in den USA", "datum" => "2026-09-30", "kategorie" => household.food.to_s, "waehrung" => "USD",
      "betrag" => "10,80", "kurs" => "1,08", "kurs_quelle" => "ezb", "bezahlt_von" => household.anna.to_s,
      "aufteilung" => "equal", "teil" => household.anna.to_s,
    }

    response = server.post_form("/ausgaben/#{id}", form, {Web::IDENTITY_COOKIE => household.anna.to_s})

    response.status_code.should eq 303
    saved = store.get_expense(id)
    {saved.title, saved.fx_rate, saved.fx_source, saved.amount_cents}
      .should eq({"Einkauf in den USA", 1.08, Domain::FXSource::Ecb, 1000})
  end
end
