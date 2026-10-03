require "./spec_helper"

describe Zipfelkasse::LogFormat do
  it "writes one logfmt line with the attributes in order and the error last" do
    Zipfelkasse::Log.warn(exception: Exception.new("bad value"),
      &.emit("hello world", key: "a b", list: ["x", "y"], none: [] of String, n: 3))
    SPEC_LOG.to_s.should match(/\Atime=\S+ level=WARN msg="hello world" key="a b" list=\[x y\] none=\[\] n=3 err="bad value"\n\z/)
  end

  it "quotes empty values and values with quotes or equals signs" do
    Zipfelkasse::Log.info(&.emit("quotes", empty: "", eq: "a=b", quoted: %(say "hi"), plain: "ok"))
    SPEC_LOG.to_s.should contain %(empty="" eq="a=b" quoted="say \\"hi\\"" plain=ok)
  end

  it "does not log below info" do
    Zipfelkasse::Log.debug { "hidden" }
    SPEC_LOG.to_s.should be_empty
  end
end
