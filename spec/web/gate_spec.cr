require "../spec_helper"

private def request(method : String, headers : Hash(String, String)) : HTTP::Request
  http_headers = HTTP::Headers{"Host" => "example.com"}
  headers.each { |name, value| http_headers[name] = value }
  HTTP::Request.new(method, "/einstellungen", http_headers)
end

describe Web::Gate do
  use_household

  describe "#same_origin?" do
    {
      "a GET from a foreign site"                         => {"GET", {"Sec-Fetch-Site" => "cross-site", "Origin" => "https://evil.example"}, true},
      "a POST from a foreign site"                        => {"POST", {"Sec-Fetch-Site" => "cross-site", "Origin" => "https://evil.example"}, false},
      "a POST from a site of the same registrable domain" => {"POST", {"Sec-Fetch-Site" => "same-site"}, false},
      "a POST that the browser calls same-origin"         => {"POST", {"Sec-Fetch-Site" => "same-origin", "Origin" => "https://evil.example"}, true},
      "a POST that the user typed into the address bar"   => {"POST", {"Sec-Fetch-Site" => "none"}, true},
      "a POST with an Origin that matches the host"       => {"POST", {"Origin" => "http://example.com"}, true},
      "a POST with a foreign Origin"                      => {"POST", {"Origin" => "https://evil.example"}, false},
      "a POST with the Origin null"                       => {"POST", {"Origin" => "null"}, false},
      "a POST with an empty Origin"                       => {"POST", {"Origin" => ""}, true},
      "a POST without any browser header, like curl"      => {"POST", {} of String => String, true},
    }.each do |name, (method, headers, allowed)|
      it "#{allowed ? "allows" : "rejects"} #{name}" do
        Web::Gate.new(household.deps).same_origin?(request(method, headers)).should eq allowed
      end
    end
  end

  describe "#login_path" do
    it "remembers the page of a GET request" do
      request = HTTP::Request.new("GET", "/salden?x=1")

      Web::Gate.new(household.deps).login_path(request).should eq "/wer?zurueck=%2Fsalden%3Fx%3D1"
    end

    it "does not remember the home page or a POST" do
      gate = Web::Gate.new(household.deps)

      gate.login_path(HTTP::Request.new("GET", "/")).should eq "/wer"
      gate.login_path(HTTP::Request.new("POST", "/salden")).should eq "/wer"
    end
  end
end
