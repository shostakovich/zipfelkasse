require "./e2e_helper"

# The comparison must ignore what a browser ignores and catch what a user
# would see.
describe E2E::DOM do
  canon = ->(html : String) { E2E::DOM.canonical("<!doctype html><html><body>#{html}</body></html>") }

  it "ignores entity spelling and attribute order" do
    canon.call(%(<p class="a  b" title="&#34;x&#34; &#43; y">Tom &amp; &#39;Jerry&#39;</p>))
      .should eq canon.call(%(<p title='"x" + y' class="a b">Tom &amp; 'Jerry'</p>))
  end

  it "ignores whitespace a browser does not render" do
    canon.call("<div>\n  <p>\n    Hallo\n  </p>\n</div>")
      .should eq canon.call("<div><p>Hallo</p></div>")
  end

  it "keeps whitespace between inline elements" do
    canon.call("<p>Bezahlt von <strong>Anna</strong> für <strong>Ben</strong></p>")
      .should_not eq canon.call("<p>Bezahlt von<strong>Anna</strong> für <strong>Ben</strong></p>")
  end

  it "sees different text, attributes and elements" do
    canon.call(%(<input name="betrag" value="10,00">)).should_not eq canon.call(%(<input name="betrag" value="10,0">))
    canon.call(%(<option value="1" selected>A</option>)).should_not eq canon.call(%(<option value="1">A</option>))
    canon.call(%(<p>&lt;b&gt;</p>)).should_not eq canon.call(%(<p><b></b></p>))
  end

  it "treats boolean attributes by presence" do
    canon.call(%(<input checked>)).should eq canon.call(%(<input checked="checked">))
  end

  it "finds injected scripts and handlers" do
    doc = XML.parse_html(%(<script src="/static/app.js"></script><p>&lt;script&gt;</p>))
    E2E::DOM.injected_scripts(doc).should be_empty
    E2E::DOM.injected_scripts(XML.parse_html(%(<p><script>alert(1)</script></p>))).size.should eq 1
    E2E::DOM.injected_scripts(XML.parse_html(%(<img src=x onerror="alert(1)">))).size.should eq 1
  end
end

describe E2E::Compare do
  it "compares JSON structurally, numbers by value" do
    E2E::Compare.json(JSON.parse(%({"b":1,"a":[1.0,"x"]}))).should eq E2E::Compare.json(JSON.parse(%({"a":[1,"x"],"b":1.0})))
    E2E::Compare.json(JSON.parse(%({"a":1}))).should_not eq E2E::Compare.json(JSON.parse(%({"a":2})))
  end

  it "looks into JSON inside strings (MCP tool results)" do
    a = JSON.parse(%({"text":"{\\"x\\":1,\\"y\\":2}"}))
    b = JSON.parse(%({"text":"{\\"y\\":2,\\"x\\":1}"}))
    E2E::Compare.json(a).should eq E2E::Compare.json(b)
  end

  it "shows where texts differ" do
    E2E::Compare.text_diff("a\nb\nc\n", "a\nX\nc\n").should contain("- b")
  end
end
