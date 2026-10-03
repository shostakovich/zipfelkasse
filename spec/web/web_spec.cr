require "./web_helper"

describe Zipfelkasse::Web do
  it "sends visitors without identity to the who page" do
    with_server do |srv|
      res = srv.get("/salden?x=1")
      res.status_code.should eq 303
      res.headers["Location"].should eq "/wer?zurueck=%2Fsalden%3Fx%3D1"
      srv.get("/").headers["Location"].should eq "/wer"
      srv.get("/", who_cookie(42)).status_code.should eq 303
    end
  end

  it "selects a person and remembers it in a cookie" do
    with_server do |srv|
      id = must_participant(srv.store, "Anna")
      res = srv.post_form("/wer", {"id" => id.to_s, "zurueck" => "/salden"})
      res.status_code.should eq 303
      res.headers["Location"].should eq "/salden"
      res.cookies[Zipfelkasse::Web::IDENTITY_COOKIE].value.should eq id.to_s
      srv.get("/wer").body.should contain "Anna"
    end
  end

  it "answers health checks and unknown paths" do
    with_server do |srv|
      srv.get("/healthz").body.should eq "ok\n"
      srv.get("/gibtsnicht", who_cookie(must_participant(srv.store, "Anna"))).status_code.should eq 404
    end
  end
end
