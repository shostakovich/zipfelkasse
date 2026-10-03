require "./web_helper"

# Anna, Ben and Cleo; Anna is logged in.
private def with_group(&)
  with_server do |srv|
    f = ExpenseFixture.new(srv.store)
    yield srv, f, who_cookie(f.anna)
  end
end

private def page(srv : TestServer, path : String, cookies) : {Int32, String}
  res = srv.get(path, cookies)
  {res.status_code, HTML.unescape(res.body)}
end

describe "balances page" do
  it "shows balances with bars and suggests reimbursements" do
    with_group do |srv, f, me|
      f.must_create(f.equal("Einkauf", 3000, "2026-09-30", f.anna, f.anna, f.ben, f.cleo))

      status, body = page(srv, "/salden", me)
      status.should eq 200
      body.should contain %(<a href="/salden" aria-current="page">)
      body.should contain "<strong>Ben</strong> schuldet <strong>Anna</strong>"
      body.should contain %(href="/ausgaben/neu?an=#{f.anna}&betrag=1000&rueckzahlung=1&von=#{f.ben}")
      ["20,00 €", "-10,00 €", "width: 100%", "width: 50%"].each { |want| body.should contain want }
      body.should contain %(<div class="balance-row me">)
      body.should contain %(<div class="balance-row negative-row">)

      back = Zipfelkasse::Store::ExpenseInput.new(title: "Rückzahlung", date: date("2026-10-01"), paid_by: f.ben,
        amount_cents: 1000, reimbursement: true, parts: [Zipfelkasse::Domain::Part.new(f.anna)])
      f.must_create(back)
      _, body = page(srv, "/salden", me)
      body.should_not contain "<strong>Ben</strong> schuldet"
      body.should contain "<strong>Cleo</strong> schuldet <strong>Anna</strong>"
    end
  end

  it "hides archived people without a balance and shows the empty states" do
    with_server do |srv|
      anna = must_participant(srv.store, "Anna")
      dora = must_participant(srv.store, "Dora")
      srv.store.set_participant_archived(anna, dora, true)
      _, body = page(srv, "/salden", who_cookie(anna))
      body.should_not contain "Dora"
      body.should contain %(<div class="balance-row me">)
      body.should_not contain "balance-bar"
      body.should contain "Alles ausgeglichen – niemand muss etwas zurückzahlen."
    end
  end
end
