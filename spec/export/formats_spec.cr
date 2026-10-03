require "../spec_helper"

describe Export do
  describe ".cell" do
    {"=SUM(A1)" => "'=SUM(A1)", "+49 Telefon" => "'+49 Telefon", "-Rabatt" => "'-Rabatt", "@home" => "'@home",
     "\tTab" => "'\tTab", "\rReturn" => "'\rReturn", "Miete" => "Miete", "a=b" => "a=b", "" => ""}.each do |text, cell|
      it "turns #{text.inspect} into #{cell.inspect}" do
        Export.cell(text).should eq cell
      end
    end
  end

  describe ".sgml" do
    it "collapses whitespace and line breaks" do
      Export.sgml("Zeile 1\n  Zeile\t2", 100).should eq "Zeile 1 Zeile 2"
    end

    it "cuts to the length before escaping and drops the blank at the cut" do
      Export.sgml("Sehr langer Titel mit <Sonderzeichen>", 32).should eq "Sehr langer Titel mit &lt;Sonderzei"
      Export.sgml("ab cd", 3).should eq "ab"
    end

    it "escapes ampersands and angle brackets" do
      Export.sgml("Café & <Kuchen>", 100).should eq "Café &amp; &lt;Kuchen&gt;"
    end
  end
end
