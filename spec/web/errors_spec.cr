require "../spec_helper"

describe "Web errors" do
  use_household

  it "answers an unexpected error with the error page and a log entry" do
    server = TestServer.new(Config.new, household.store)
    get("/kaputt") { |_| raise "Platte voll" }

    response = server.get("/kaputt", {Web::IDENTITY_COOKIE => household.anna.to_s})

    response.status_code.should eq 500
    response.body.should contain "Da ist etwas schiefgegangen."
    response.body.should contain "Du bist <strong>Anna</strong>"
    SPEC_LOG.to_s.should contain %(level=ERROR msg="Platte voll" err="Platte voll")
  end

  it "answers with plain text when even the error page cannot be rendered" do
    server = TestServer.new(Config.new, household.store)
    cookies = {Web::IDENTITY_COOKIE => household.anna.to_s}
    store.close

    response = server.get("/salden", cookies)

    response.status_code.should eq 500
    response.headers["Content-Type"].should start_with "text/plain"
    response.body.should eq "Da ist etwas schiefgegangen.\n"
  end
end
