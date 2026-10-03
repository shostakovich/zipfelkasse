require "../spec_helper"

describe "ECB files" do
  ecb = FakeECB.new(Time.utc(2026, 10, 2))
  after_all { ecb.close }

  describe ".parse_xml" do
    it "reads every rate of every day" do
      rates = FX.parse_xml(ecb.file(FX::RECENT))
      days = rates.map(&.date).uniq!

      rates.size.should eq days.size * FakeECB::BASE.size
      {days.min, days.max}.should eq({Time.utc(2026, 7, 6), Time.utc(2026, 10, 2)})
      rates.first(2).map { |rate| {rate.currency, rate.source} }.should eq [{"USD", Domain::FXSource::Ecb}, {"JPY", Domain::FXSource::Ecb}]
    end

    it "rejects a cut-off file instead of reading fewer rates" do
      xml = ecb.file(FX::RECENT)
      expect_raises(Exception, /xml: /) { FX.parse_xml(xml[0, xml.index!("rate='") + 12]) }
    end
  end

  describe ".parse_ecb_rate" do
    {"1.1298" => 1.1298, " 2 " => 2.0, "N/A" => nil, "" => nil, "-1" => nil, "NaN" => nil, "Inf" => nil}.each do |text, rate|
      it "reads #{text.inspect} as #{rate.inspect}" do
        FX.parse_ecb_rate(text).should eq rate
      end
    end
  end
end
