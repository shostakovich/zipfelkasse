require "../spec_helper"

describe "Web.safe_return" do
  {
    "/aktivitaet"           => "/aktivitaet",
    "/salden?x=1#a"         => "/salden?x=1#a",
    "/ausgaben/neu?von=%2F" => "/ausgaben/neu?von=%2F",
    "/a?%zz"                => "/a?%zz",
    "/a#/../b"              => "/a#/../b",
    "/ä"                    => "/ä",
  }.each do |target, kept|
    it "keeps the local target #{target.inspect}" do
      Web.safe_return(target).should eq kept
    end
  end

  [
    "", "evil", "https://evil", "//evil", "/\\evil", "/a\\b", "/wer?zurueck=/",
    "/%09/evil.example/x", "/\t/evil.example/x", "/\r\n/evil.example", "/%2F/evil.example",
    "/%77er", "/%zz", "/a%2", "/a#b%", "/a?b#%zz", "/%C2%85",
  ].each do |target|
    it "falls back to the home page for #{target.inspect}" do
      Web.safe_return(target).should eq "/"
    end
  end
end
