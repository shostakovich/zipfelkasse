require "../spec_helper"

describe "ECB files" do
  ecb = FakeECB.new(Time.utc(2026, 10, 2))
  after_all { ecb.close }

  describe ".parse_xml" do
    it "reads every rate of every day" do
      rates = FX.parse_xml(String.new(ecb.file(FX::FILE_90D)))
      days = rates.map(&.date).uniq!

      rates.size.should eq days.size * FakeECB::BASE.size
      result = FX::LoadResult.new(rates)
      {result.from, result.to, result.currencies.size}.should eq({days.min, days.max, FakeECB::BASE.size})
      rates.first(2).map { |rate| {rate.currency, rate.source} }.should eq [{"USD", Domain::FXSource::Ecb}, {"JPY", Domain::FXSource::Ecb}]
    end

    it "rejects a cut-off file instead of reading fewer rates" do
      xml = String.new(ecb.file(FX::FILE_DAILY))
      expect_raises(Exception, /xml: /) { FX.parse_xml(xml[0, xml.index!("rate='") + 12]) }
    end
  end

  describe ".parse_hist_csv" do
    it "skips currencies without a rate on a day" do
      csv = <<-CSV
        Date,USD,JPY,BGN,CYP,
        2026-10-01,1.1298,178.49,N/A,N/A,
        2024-01-03,1.0919,155.94,1.9558,N/A,
        CSV

      FX.parse_hist_csv(IO::Memory.new(csv)).map(&.currency).tally.should eq({"USD" => 2, "JPY" => 2, "BGN" => 1})
    end

    it "rejects a file that does not start with the date column" do
      expect_raises(Exception, /csv: unexpected header/) { FX.parse_hist_csv(IO::Memory.new("Foo,USD\n")) }
    end
  end

  describe ".parse_hist_zip" do
    it "reads the CSV in the ZIP" do
      rates = FX.parse_hist_zip(ecb.file(FX::FILE_HIST))

      rates.map(&.currency).tally.keys.sort.should eq FakeECB::BASE.keys.sort
      rates.map(&.date).min.should eq Time.utc(2023, 12, 1)
    end

    it "rejects a file that is not a ZIP" do
      expect_raises(Exception, /zip: /) { FX.parse_hist_zip("not a zip".to_slice) }
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
