require "./expense_helper"

describe "activity page" do
  it "lists changes to expenses and settings" do
    with_expense_group do |g|
      e = g.create(g.form)
      v = g.form
      v["titel"] = "Einkauf groß"
      g.post("/ausgaben/#{e.id}", v)
      g.post("/ausgaben/#{e.id}/loeschen")
      g.store.create_category(nil, "Regel") # system entry

      status, body = g.get("/aktivitaet")
      status.should eq 200
      [
        "Heute", "<strong>Anna</strong> hat <em>„Einkauf“</em> angelegt", "<em>„Einkauf groß“</em> geändert",
        "<em>„Einkauf groß“</em> gelöscht", "Titel: <del>Einkauf</del> → <ins>Einkauf groß</ins>",
        %(href="/ausgaben/#{e.id}"), "<strong>Automatisch</strong>: Kategorie „Regel“ hinzugefügt",
        # the amount for created and deleted, not for changed (the changes list it)
        %(„Einkauf“</em> angelegt <span class="amount), %(„Einkauf groß“</em> gelöscht <span class="amount),
        "„Einkauf groß“</em> geändert.",
        %(<a href="/aktivitaet" aria-current="page">),
      ].each { |want| body.should contain want }
    end
  end

  it "pages through older entries" do
    with_expense_group do |g|
      (Zipfelkasse::Web::ACTIVITY_PAGE_SIZE + 5).times { |i| g.store.create_category(g.anna, "Eintrag #{i}") }
      _, body = g.get("/aktivitaet")
      body.should contain "„Eintrag 54“"
      body.should_not contain "„Eintrag 4“"
      i = body.index("/aktivitaet?vor=") || fail "no link to older entries"
      _, body = g.get(body[i...body.index!('"', i)])
      body.should contain "„Eintrag 4“"
      body.should_not contain "„Eintrag 54“"
      body.should_not contain "Ältere anzeigen"
    end
  end
end
